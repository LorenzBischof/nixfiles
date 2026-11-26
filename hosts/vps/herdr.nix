# The Herdr front ends to the agents in agents.nix: ovis's web UI and the
# Herdr phone app, both on herdr-core (`hc`).
{
  config,
  pkgs,
  agentUser,
  ...
}:
let
  domain = config.my.homelab.domain;
  llmAgents = pkgs.llm-agents;

  # Agents driven from a phone over the tailnet, through ovis's web UI.
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
in
{
  users.users.${agentUser.name} = {
    # The Herdr phone app, which reaches hc over SSH (`hc connect`).
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBH8bxoqLrAa1VDpuTVGVrMpqAFxhj3WtvuaktzrHYRL herdr-mobile"
    ];
    packages = [ ovis ];
  };

  systemd.user.services.ovis = {
    description = "ovis web UI for herdr-core terminals";
    unitConfig.ConditionUser = agentUser.name;
    wantedBy = [ "default.target" ];
    inherit (agentUser) path;
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

  my.homelab.ports = [ port ];
  # ovis: nginx only.
  my.homelab.loopbackClients.${toString port}.users = [ config.services.nginx.user ];
}
