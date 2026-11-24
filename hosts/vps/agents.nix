{
  config,
  pkgs,
  inputs,
  ...
}:
let
  domain = config.my.homelab.domain;
  llmAgents = import ../../packages/llm-agents.nix { inherit inputs pkgs; };

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
    #
    # TODO: chat mode shows no prompt cache state. The second patch reads until
    # when the Claude prompt cache stays warm from the transcript, beside the
    # context ring it already reads there, and shows that time next to the ring.
    # No upstream issue or PR (none on devswha/ovis as of 2026-11). Drop once
    # ovis shows the cache state itself.
    ovis-unwrapped = llmAgents.ovis.unwrapped.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        ./ovis-claude-suggestion.patch
        ./ovis-cache-mark.patch
      ];
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

  # `hc run --bg` with the same arguments, in a hidden pane; prints the
  # address. The pane goes beside the caller's own, or, for a caller that is
  # itself a hidden worker, beside its nearest ancestor in the window. With
  # none in the window it stays a plain hidden worker.
  #
  # Why a labeled pane rather than a plain `hc run --bg`: the Herdr app hides
  # unlabeled workers, but Ovis opens each one as a tab of its own. Labeled
  # with the caller's space and tab, it joins that tab instead, and Ovis on
  # the phone shows a tab's panes as numbers to switch between.
  #
  # TODO: the app shows a labeled terminal too, so the pane is first written
  # into the app's layout document as hidden, then labeled; in that order the
  # app never shows it. The app has no command to hide a pane:
  # https://github.com/herdrdev/herdr-app/issues/1301 (open as of 2026-11). A
  # hidden pane still makes its tab act as split (frame, move grip, a zoom
  # that does nothing):
  # https://github.com/herdrdev/herdr-app/issues/1251 (open as of 2026-11).
  # Drop the document write once the app ships a hide command; drop the whole
  # script if Ovis stops giving unlabeled workers tabs (no upstream issue yet).
  hcRunHidden = pkgs.writeShellApplication {
    name = "hc-run-hidden";
    runtimeInputs = [
      llmAgents.herdr-core
      pkgs.jq
    ];
    text = ''
      t=$(hc run --bg "$@" | jq -r .address)
      echo "$t"
      # The nearest of the caller and its ancestors that is in the window.
      at=''${HC_TERMINAL_ID:-} labels=()
      while [ -n "$at" ]; do
        info=$(hc get "$at" 2>/dev/null) || exit 0
        mapfile -t labels < <(jq -r '.labels // {} | select(."herdr.tab") | "herdr.space=\(."herdr.space")", "herdr.tab=\(."herdr.tab")"' <<<"$info")
        [ ''${#labels[@]} -eq 0 ] || break
        at=$(jq -r '.parent // empty' <<<"$info")
      done
      [ ''${#labels[@]} -gt 0 ] || exit 0
      # A write the app got in first is refused as a conflict: read again.
      # Anything else (no document, $at not in it) leaves it unlabeled.
      for _ in 1 2 3 4 5; do
        if ! reply=$(echo '{"id":1,"method":"doc.get","params":{"name":"herdr-app"}}' | hc connect |
          jq -c --arg me "$at" --arg t "$t" 'if any(.result.value | ..; .content?.terminal? == $me) then
            {id: 1, method: "doc.set", params: {name: "herdr-app", version: .result.version,
              value: (.result.value | (.. | objects | select(any(.children[]?; .content.terminal == $me)) | .children) += [{type: "block", id: "p-\($t)", content: {terminal: $t}, hidden: true}])}}
            else error("\($me) is not in the herdr-app layout") end' | hc connect); then
          break
        fi
        if jq -e .result >/dev/null <<<"$reply"; then
          hc label "$t" "''${labels[@]}" >/dev/null
          exit 0
        fi
        jq -e '.error.data.kind == "conflict"' >/dev/null <<<"$reply" || break
      done
      echo "hc-run-hidden: $t stays an unlabeled hidden worker ''${reply:-}" >&2
    '';
  };

  # Waits for the user to open the PR from a compare link the agent gave them,
  # then for its checks, and prints gh's check table once at the end. Run from
  # the clone, after pushing BRANCH to the `fork` remote. Agents start it with
  # hc-run-hidden and wait for it (see agent-instructions.md).
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
        # The PR whose head is the branch's pushed commit, re-read so a later
        # push still matches. An older PR from the same branch, or another
        # fork's branch of the same name, has another head. Any state: the
        # user may merge it before the next poll.
        sha=$(git rev-parse "fork/$branch")
        n=$(gh pr list -R "$repo" --head "$branch" --state all --json number,headRefOid \
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

  # A throwaway x86_64 machine with KVM, from .github/workflows/vm.yml: see
  # there for how it is reached. It is for testing; two rules keep what it
  # sends back from reaching the vps's own store:
  # - `agent` stays an untrusted nix user, so the daemon refuses unsigned paths
  #   and a client-set `builders`;
  # - `gha-vm nix` builds in the machine's store (`--store ssh-ng://`) and
  #   copies nothing back.
  ghaVm = pkgs.writeShellApplication {
    name = "gha-vm";
    runtimeInputs = [
      gh
      pkgs.dumbpipe
      pkgs.openssh
      pkgs.coreutils
    ];
    text = ''
      repo=lorenzbischof-agents/nixfiles
      state=''${XDG_STATE_HOME:-$HOME/.local/state}/gha-vm
      key=$state/id_ed25519
      usage() {
        echo "usage: gha-vm up [MINUTES] | ssh NAME [ARGS...] | nix NAME COMMAND [ARGS...] | down NAME | ls" >&2
        exit 2
      }
      vm() {
        [[ ''${1-} =~ ^gha-[0-9]+$ && -d $state/$1 ]] || { echo "gha-vm: no machine ''${1-}" >&2; exit 1; }
        dir=$state/$1 id=''${1#gha-}
      }
      # Cancels run $id and forgets $dir; keeps it when the run may still be up.
      stop() {
        gh run cancel "$id" -R "$repo" >/dev/null 2>&1 ||
          [ "$(gh run view "$id" -R "$repo" --json status -q .status)" = completed ] || return 1
        rm -r "$dir"
      }
      case ''${1-} in
      up)
        mkdir -p "$state"
        [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -C gha-vm -f "$key"
        # The runner takes openssh and dumbpipe from our nixpkgs revision, and
        # dumbpipe with the same override as ours, so both ends run the same one.
        url=$(gh workflow run vm.yml -R "$repo" -f ssh_key="$(<"$key.pub")" -f minutes="''${2:-60}" \
          -f nixpkgs=${inputs.nixpkgs.rev} | grep -o "https://github.com/$repo/actions/runs/[0-9]*$") ||
          { echo "gha-vm: gh gave no run URL" >&2; exit 1; }
        id=''${url##*/} name=gha-''${url##*/}
        echo "gha-vm: $name is $url" >&2
        # From here on `down` can find it, and any failure stops it.
        dir=$state/$name
        mkdir "$dir"
        trap 'stop || echo "gha-vm: $name may still be running: gha-vm down $name" >&2' EXIT
        fail() { echo "gha-vm: $name $1" >&2; exit 1; }
        # A new run takes a few seconds to show up in the API.
        sha=""
        for _ in $(seq 30); do
          sha=$(gh run view "$id" -R "$repo" --json headSha -q .headSha 2>/dev/null) && break
          sleep 2
        done
        [ -n "$sha" ] || fail "never showed up"
        ticket=""
        for _ in $(seq 120); do
          # Set by that run itself, not by anyone else who can write statuses.
          # The newest one counts: a stopped run follows its pending status.
          ticket=$(gh api "repos/$repo/commits/$sha/statuses?per_page=100" -q "first(.[] | select(
            .context == \"vm/$id\" and .creator.login == \"github-actions[bot]\")) |
            select(.state == \"pending\" and .target_url == \"$url\") | .description")
          [ -z "$ticket" ] || break
          [ "$(gh run view "$id" -R "$repo" --json status -q .status)" != completed ] || fail "ended before it came up"
          sleep 5
        done
        # It becomes part of a ProxyCommand.
        [[ $ticket =~ ^endpoint[a-z0-9]+$ ]] || fail "never came up"
        # The pipe is authenticated to the runner's endpoint, so pinning the
        # host key it first shows is enough.
        cat >"$dir/ssh_config" <<EOF
      Host $name
        User runner
        ProxyCommand dumbpipe connect $ticket 2>>$dir/dumbpipe.log
        IdentityFile $key
        IdentitiesOnly yes
        UserKnownHostsFile $dir/known_hosts
        StrictHostKeyChecking accept-new
      EOF
        trap - EXIT
        echo "$name"
        ;;
      ssh)
        vm "''${2-}"
        exec ssh -F "$dir/ssh_config" "''${@:2}"
        ;;
      nix)
        vm "''${2-}"
        [ -n "''${3-}" ] || usage
        NIX_SSHOPTS="-F $dir/ssh_config" exec nix "$3" --eval-store auto --store "ssh-ng://$2" "''${@:4}"
        ;;
      down)
        vm "''${2-}"
        stop || { echo "gha-vm: could not cancel run $id" >&2; exit 1; }
        ;;
      ls)
        # Machines whose run has ended are gone: forget them.
        for dir in "$state"/gha-*/; do
          [ -d "$dir" ] || continue
          name=$(basename "$dir")
          if [ "$(gh run view "''${name#gha-}" -R "$repo" --json status -q .status)" = completed ]; then
            rm -r "$dir"
          else
            echo "$name"
          fi
        done
        ;;
      *) usage ;;
      esac
    '';
  };
in
{
  # The runner builds the same file: see there.
  nixpkgs.overlays = [
    (_final: prev: {
      dumbpipe = prev.callPackage ../../packages/dumbpipe.nix { inherit (prev) dumbpipe; };
    })
  ];

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
      hcRunHidden
      ghaVm
      pkgs.git
      pkgs.jq
      pkgs.ripgrep
    ];
  };

  # The agents are most of what this box (4 cores, 23G, no swap) is for, so
  # they may use nearly all of it - but a runaway agent must not starve the
  # services beside it (cook-server, galaxus-mcp, nginx, which together need
  # about 1G). The memory ceiling leaves those ~3G; the low CPU and IO weights
  # let agents use every core when the box is idle and make them yield the
  # moment another service wants it. A cap at 6G once throttled the slice so
  # hard that hc stopped answering with ~10 Claude sessions open, each with
  # its own basic-memory MCP. On the whole slice rather than a unit, because
  # hc creates its units at runtime.
  systemd.slices."user-${toString uid}" = {
    overrideStrategy = "asDropin";
    sliceConfig = {
      MemoryHigh = "19G";
      MemoryMax = "20G";
      TasksMax = 4096;
      CPUWeight = 20;
      IOWeight = 20;
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
    # Local to this host over stdio, with no network service: the graph lives
    # in ~agent/basic-memory and only the agents here use it. A shared server
    # was tried and reverted (2026-11-13) for its unauthenticated REST API.
    basicMemory = {
      enable = true;
      reflect.user = user;
    };
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
    # What `--approve-for-me` sets: commands outside the workspace-write
    # sandbox go to Codex's automatic reviewer rather than wait for a person
    # who may not be watching. hc needs that too: its socket is a network
    # connection to the sandbox, and network access stays off.
    codex.config = {
      approvals_reviewer = "auto_review";
      approval_policy = "on-request";
      sandbox_mode = "workspace-write";
    };
  };

  # Not programs.git.config, which would apply to lbischof too. The agent
  # instructions describe the GitHub setup above, so they are generated next
  # to it: Claude Code reads ~/CLAUDE.md as a parent of every working
  # directory, Codex reads only $CODEX_HOME/AGENTS.md (~/.codex, 0700 for its
  # auth.json) and the repo it works in. ~/CLAUDE.md is the file itself: an
  # `@AGENTS.md` import in a linked file resolves next to its target in
  # /nix/store and loads nothing.
  systemd.tmpfiles.rules = [
    "d /home/${user}/.config 0755 ${user} ${config.users.users.${user}.group} -"
    "d /home/${user}/.config/git 0755 ${user} ${config.users.users.${user}.group} -"
    "d /home/${user}/.codex 0700 ${user} ${config.users.users.${user}.group} -"
    "L+ /home/${user}/.config/git/config - - - - ${gitConfig}"
    "L+ /home/${user}/CLAUDE.md - - - - ${./agent-instructions.md}"
    "L+ /home/${user}/.codex/AGENTS.md - - - - ${./agent-instructions.md}"
    # hc templates (`hc run bug-reviewer "…"`), linked one by one so the folder
    # stays writable for templates still being tried out.
    "d /home/${user}/.config/herdr-core 0755 ${user} ${config.users.users.${user}.group} -"
    "d /home/${user}/.config/herdr-core/templates 0755 ${user} ${config.users.users.${user}.group} -"
    # Removes the link left from when bug-reviewer was called reviewer; drop
    # once the vps has switched past this.
    "r /home/${user}/.config/herdr-core/templates/reviewer.md"
    "L+ /home/${user}/.config/herdr-core/templates/bug-reviewer.md - - - - ${./hc-templates/bug-reviewer.md}"
    "L+ /home/${user}/.config/herdr-core/templates/simplifier.md - - - - ${./hc-templates/simplifier.md}"
    "L+ /home/${user}/.config/herdr-core/templates/screenshotter.md - - - - ${./hc-templates/screenshotter.md}"
    "L+ /home/${user}/.config/herdr-core/templates/security-reviewer.md - - - - ${./hc-templates/security-reviewer.md}"
  ];

  my.homelab.ports = [ port ];
  # ovis: nginx only.
  my.homelab.loopbackClients.${toString port}.users = [ config.services.nginx.user ];
}
