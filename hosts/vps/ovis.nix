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
  ovis = llmAgents.ovis.override { runtime = "herdr-core"; };
  port = 7317;

  # A normal login user, not a system user: hc needs a lingering user manager
  # to start its units under. Not lbischof, whose passwordless sudo would hand
  # every agent root.
  user = "agent";
  # Pinned so the slice below can name it.
  uid = 1001;

  # Agents push to forks in lorenzbischof-agents and open PRs into
  # LorenzBischof's repos. The include sets git's auth header for github.com;
  # a credential helper would also be asked to store and erase.
  gitConfig = pkgs.writeText "agent-gitconfig" ''
    [user]
      name = LorenzBischof
      email = 1837725+LorenzBischof@users.noreply.github.com
    [include]
      path = ${config.age.secrets.agents-push-org.path}
  '';
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
      pkgs.gh
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

  # Not programs.git.config, which would apply to lbischof too. environment.d
  # gives GH_TOKEN to every unit, read only when user@${toString uid} starts.
  systemd.tmpfiles.rules = [
    "d /home/${user}/.config 0755 ${user} ${config.users.users.${user}.group} -"
    "d /home/${user}/.config/git 0755 ${user} ${config.users.users.${user}.group} -"
    "d /home/${user}/.config/environment.d 0755 ${user} ${config.users.users.${user}.group} -"
    "L+ /home/${user}/.config/git/config - - - - ${gitConfig}"
    "L+ /home/${user}/.config/environment.d/gh.conf - - - - ${config.age.secrets.agents-pr.path}"
  ];

  my.homelab.ports = [ port ];
}
