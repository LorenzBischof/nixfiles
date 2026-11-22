{
  config,
  pkgs,
  inputs,
  ...
}:
let
  domain = config.my.homelab.domain;
  llmAgents = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};

  # Coding agents driven from a phone over the tailnet, through ovis's web UI.
  # It runs on herdr-core (`hc`) rather than herdr's own TUI server: hc keeps
  # each terminal in a "holder" user service of its own, apart from the core,
  # so a core restart or upgrade leaves the agents running, and it starts those
  # units itself through systemd-run. herdr's server instead holds every pane
  # in its one process, and under a systemd unit its upgrade path kills them
  # all - https://github.com/herdrdev/herdr/issues/4972.
  ovis = llmAgents.ovis.override {
    runtime = "herdr-core";
    # TODO: on herdr-core, Claude Code's grey prompt suggestion is refused as
    # "input box may not be empty" whenever hc's coloured and plain screen reads
    # differ by a row anywhere, far above the input box included. The patch
    # compares only the box rows when hc gives no scroll info.
    # https://github.com/devswha/ovis/issues/4321, no upstream fix yet (still
    # the whole-screen check on main and in v0.5.9 as of 2026-11). Drop once
    # ovis ships a fix for it.
    ovis-unwrapped = llmAgents.ovis.unwrapped.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./ovis-claude-suggestion.patch ];
    });
  };
  port = 7317;

  # A normal login user, not a system user: hc needs a lingering user manager
  # to start its units under. Not lbischof, whose passwordless sudo would hand
  # every agent root.
  user = "agent";
  # Pinned so the slice below can name it.
  uid = 1001;

  # Two fine-grained PATs, because one can only reach the repos of a single
  # owner: the personal token (LorenzBischof: contents read, PRs; read access
  # to public repos anywhere) and the org token (lorenzbischof-agents: full
  # access). git and gh share one rule: the org token for lorenzbischof-agents,
  # the personal token for everything else. Both keep a lifetime of at most
  # 366 days, as the NixOS enterprise refuses longer-lived fine-grained tokens
  # (the org token reads nixpkgs when forking it). Both are read from their
  # agenix file per request, so neither is in the config or the environment,
  # where `git config -l` or `env` would print it.
  orgToken = config.age.secrets.agents-push-org.path;
  personalToken = config.age.secrets.agents-pr.path;

  # git appends the operation, so this runs as `<helper> <file> get|store|erase`
  # and only answers get. Git only asks after a 401, so public clones stay
  # anonymous until GitHub demands authentication. An empty helper resets the
  # list, so the org section replaces the catch-all instead of adding to it.
  credentialHelper = pkgs.writeShellScript "git-credential-token-file" ''
    [ "$2" = get ] || exit 0
    printf 'username=x-access-token\npassword=%s\n' "$(< "$1")"
  '';
  gitConfig = pkgs.writeText "agent-gitconfig" ''
    [user]
      name = LorenzBischof
      email = 1837725+LorenzBischof@users.noreply.github.com
    [credential "https://github.com"]
      helper =
      helper = ${credentialHelper} ${personalToken}
    [credential "https://github.com/lorenzbischof-agents"]
      helper =
      helper = ${credentialHelper} ${orgToken}
  '';

  # gh only reads GH_TOKEN, so pick it per call by the same rule: the org
  # token for `gh repo fork` (the fork is created in the org) and for any
  # argument that names an org repo (`-R lorenzbischof-agents/REPO`, an API
  # path or URL), the personal token otherwise. Arguments are matched by
  # prefix, so a PR body that mentions the org changes nothing. A wrong pick
  # fails with 403/404 rather than writing anywhere, and a GH_TOKEN set by the
  # caller wins.
  gh = pkgs.writeShellApplication {
    name = "gh";
    text = ''
      if [[ -z ''${GH_TOKEN-} ]]; then
        token=${personalToken}
        if [[ "''${1-} ''${2-}" == "repo fork" ]]; then
          token=${orgToken}
        fi
        for arg in "$@"; do
          case ''${arg,,} in
            lorenzbischof-agents/* | --repo=lorenzbischof-agents/* | \
              repos/lorenzbischof-agents/* | /repos/lorenzbischof-agents/* | \
              https://github.com/lorenzbischof-agents/*)
              token=${orgToken}
              ;;
          esac
        done
        GH_TOKEN=$(< "$token")
        export GH_TOKEN
      fi
      exec ${pkgs.gh}/bin/gh "$@"
    '';
  };

  # Waits for the user to open the PR from a compare link the agent gave them,
  # then for its checks, and prints gh's check table once at the end. Run from
  # the clone, after pushing BRANCH to the `fork` remote. Agents run it as an
  # hc background terminal, whose exit wakes them (see agent-instructions.md).
  prWatch = pkgs.writeShellApplication {
    name = "pr-watch";
    runtimeInputs = [
      gh
      pkgs.git
      pkgs.coreutils
    ];
    text = ''
      repo=$1 branch=$2
      end=$((SECONDS + 7200))
      # Waits a minute, or past the 2h deadline prints $1 and gives up.
      tick() { [ "$SECONDS" -lt "$end" ] || { echo "$1"; exit 1; }; sleep 60; }
      # gh calls stay out of conditions: an error ends the watch with gh's
      # message rather than passing for "not yet".
      while :; do
        # The open PR whose head is the branch's pushed commit, re-read so a
        # later push still matches. An older PR from the same branch, or
        # another fork's branch of the same name, has another head.
        sha=$(git rev-parse "fork/$branch")
        n=$(gh pr list -R "$repo" --head "$branch" --state open --json number,headRefOid \
          -q "first(.[] | select(.headRefOid == \"$sha\") | .number) // empty")
        [ -z "$n" ] || break
        tick "no PR opened within 2h"
      done
      echo "https://github.com/$repo/pull/$n"
      # Checks register up to half a minute after each push, one workflow or
      # app at a time; --watch would stop at the first ones to finish. So wait,
      # and start over when the head moved during the watch.
      head=""
      while :; do
        now=$(gh pr view "$n" -R "$repo" --json headRefOid -q .headRefOid)
        [ "$now" != "$head" ] || break
        head=$now
        sleep 60
        left=$((end - SECONDS))
        timeout "$((left > 0 ? left : 1))" gh pr checks "$n" -R "$repo" --watch --interval 60 >/dev/null || true
        [ "$SECONDS" -lt "$end" ] || break
      done
      # A run held for a maintainer's approval has no checks, so gh pr checks
      # can't show it.
      gh run list -R "$repo" --commit "$head" --status action_required --json name,url \
        -q '.[] | "waits for approval\t\(.name)\t\(.url)"'
      gh pr checks "$n" -R "$repo"
    '';
  };
in
{
  users.users.${user} = {
    inherit uid;
    isNormalUser = true;
    # The user manager, and so ovis and every terminal, start at boot and
    # outlive every SSH session. hc would enable this itself if it were off.
    linger = true;
    # For `hc attach`.
    openssh.authorizedKeys.keys = config.users.users.lbischof.openssh.authorizedKeys.keys ++ [
      # The Herdr phone app, which reaches hc over SSH (`hc connect`).
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBH8bxoqLrAa1VDpuTVGVrMpqAFxhj3WtvuaktzrHYRL herdr-mobile"
    ];
    packages = [
      ovis
      # On PATH as well as inside the ovis wrapper, for `hc attach` over SSH.
      llmAgents.herdr-core
      gh
      prWatch
      pkgs.git
      pkgs.jq
      pkgs.ripgrep
    ];
  };

  # A runaway agent must not take the rest of the box (4 cores, 23G, no swap)
  # down with it. On the whole slice rather than a unit, because hc creates its
  # units at runtime.
  systemd.slices."user-${toString uid}" = {
    overrideStrategy = "asDropin";
    sliceConfig = {
      MemoryHigh = "6G";
      MemoryMax = "8G";
      TasksMax = 1024;
      CPUQuota = "300%";
    };
  };

  systemd.user.services.ovis = {
    description = "ovis web UI for herdr-core terminals";
    unitConfig.ConditionUser = user;
    wantedBy = [ "default.target" ];
    # systemd-run for hc, and the tools its terminals inherit. Profiles rather
    # than store paths, so package bumps reach new terminals without touching
    # the unit.
    path = [
      "/etc/profiles/per-user/${user}"
      "/run/current-system/sw"
    ];
    environment = {
      # Loopback only; nginx below is the one way in.
      HOST = "127.0.0.1";
      PORT = toString port;
      OVIS_TELEMETRY = "0";
      # No account.ovis.sh sign-in, so no relay or hosted app on top of the
      # tailnet. The relay is off by default as well.
      OVIS_ACCOUNT_SERVICE_URL = "off";
    };
    serviceConfig = {
      # OVIS_TOKEN. Without it every process on this host is loopback to ovis
      # and gets in unpaired - galaxus-mcp, cook-server and nginx included.
      EnvironmentFile = config.age.secrets.ovis-token.path;
      ExecStart = "${ovis}/bin/ovis";
      # The terminals live in hc's units, so restarting this costs nothing.
      Restart = "always";
      RestartSec = "5s";
    };
  };

  # The phone's way in. No listen address of its own, so it answers only on
  # the tailnet address from configuration.nix. recommendedProxySettings adds
  # the forwarding headers by which ovis tells a proxied request from a local
  # one, so it asks for the token or a paired device.
  services.nginx.virtualHosts."ovis.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
      # Live updates are SSE and must not be buffered.
      extraConfig = "proxy_buffering off;";
    };
  };

  # Both MCP servers run locally, so no DNS, TLS or nginx hop is needed.
  my.programs.agents = {
    enable = true;
    mcpServers = {
      cooklang = {
        type = "http";
        url = "http://127.0.0.1:3001/mcp";
      };
      galaxus = {
        type = "http";
        url = "http://127.0.0.1:3002/mcp";
      };
    };
  };

  # Not programs.git.config, which would apply to lbischof too. The agent
  # instructions describe the GitHub setup above, so they are generated next
  # to it: Claude Code reads ~/CLAUDE.md as a parent of every working
  # directory, Codex reads only $CODEX_HOME/AGENTS.md (~/.codex, 0700 for its
  # auth.json) and the repo it works in.
  systemd.tmpfiles.rules = [
    "d /home/${user}/.config 0755 ${user} ${config.users.users.${user}.group} -"
    "d /home/${user}/.config/git 0755 ${user} ${config.users.users.${user}.group} -"
    "d /home/${user}/.codex 0700 ${user} ${config.users.users.${user}.group} -"
    "L+ /home/${user}/.config/git/config - - - - ${gitConfig}"
    "L+ /home/${user}/AGENTS.md - - - - ${./agent-instructions.md}"
    "L+ /home/${user}/CLAUDE.md - - - - ${pkgs.writeText "CLAUDE.md" "@AGENTS.md\n"}"
    "L+ /home/${user}/.codex/AGENTS.md - - - - ${./agent-instructions.md}"
    # hc templates (`hc run reviewer "…"`), linked one by one so the folder
    # stays writable for templates still being tried out.
    "d /home/${user}/.config/herdr-core 0755 ${user} ${config.users.users.${user}.group} -"
    "d /home/${user}/.config/herdr-core/templates 0755 ${user} ${config.users.users.${user}.group} -"
    "L+ /home/${user}/.config/herdr-core/templates/reviewer.md - - - - ${./hc-templates/reviewer.md}"
    "L+ /home/${user}/.config/herdr-core/templates/simplifier.md - - - - ${./hc-templates/simplifier.md}"
  ];

  my.homelab.ports = [ port ];
}
