{
  config,
  pkgs,
  inputs,
  ...
}:
let
  domain = config.my.homelab.domain;

  mcpPort = 3002;

  galaxus-mcp = pkgs.callPackage ../../packages/galaxus-mcp { src = inputs.galaxus-mcp; };

  textfileDirectory = config.my.monitoring.client.textfileDirectory;
in
{
  # Product search on Galaxus/Digitec, for claude.ai. Read-only and
  # unauthenticated towards the shop: it replays the storefront's own persisted
  # GraphQL operations, so there is no account, no cart and no order data in
  # reach - the whole surface is public product data.
  systemd.services.galaxus-mcp = {
    description = "Galaxus MCP server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    environment = {
      GALAXUS_MCP_TRANSPORT = "http";
      GALAXUS_MCP_PORT = toString mcpPort;
      # No token: it binds loopback only, and the bearer check lives in nginx
      # so it can apply to the public name alone - see mcp.nix.
      GALAXUS_PORTAL = "galaxus";
      # Product names and specification labels come back in this language.
      GALAXUS_LANGUAGE = "de";
    };
    serviceConfig = {
      ExecStart = "${galaxus-mcp}/bin/galaxus-mcp-http";
      Restart = "on-failure";
      RestartSec = "5s";

      # It reads and writes nothing on disk and holds no state between requests.
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      # Unlike cooklang-mcp, which only ever talks to 127.0.0.1, this resolves
      # www.galaxus.ch - and glibc's resolver probes the available address
      # families over netlink. Denying it makes name resolution degrade in ways
      # that are hard to read off the symptom, which is every tool failing.
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      # No MemoryDenyWriteExecute, unlike cooklang-mcp: that one is Python, this
      # one is node, and V8 needs write+execute pages for its JIT. With it on,
      # node aborts before running a line of this server - SIGTRAP, a core dump
      # and a V8 stack trace, on a loop every RestartSec.
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  # Registered under the public MCP name only; mcp.nix serves the same set of
  # locations again under the tailnet name, so this is the single place the
  # server's path and port are stated. An exact match, so widening the vhost
  # later cannot publish anything else; because `proxyPass` carries a URI, nginx
  # replaces the matched path with the `/mcp` this server actually serves.
  services.nginx.virtualHosts."mcp.${domain}".locations."= /galaxus" = {
    proxyPass = "http://127.0.0.1:${toString mcpPort}/mcp";
    # Streamable HTTP responses are SSE and must not be buffered.
    extraConfig = "proxy_buffering off;";
  };

  # The shop rotates the persisted query hashes the server replays whenever it
  # deploys a new frontend, and that breaks all seven tools at once. This asks
  # the shop whether each one is still accepted - no browser, one small request
  # per operation - and exports the answer for the alert on nas to pick up.
  #
  # Re-capturing them is the part that cannot happen here: it needs the HTML and
  # the JS bundles, which this host is refused (the GraphQL endpoints answer it
  # fine). So a rotation is fixed by hand on framework, into
  # packages/galaxus-mcp/operations.json.
  systemd.services.galaxus-hash-check = {
    description = "Check the Galaxus persisted query hashes are still accepted";
    environment.GALAXUS_TEXTFILE_DIRECTORY = textfileDirectory;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${galaxus-mcp}/bin/galaxus-mcp-check-hashes";

      DynamicUser = true;
      ReadWritePaths = [ textfileDirectory ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  systemd.timers.galaxus-hash-check = {
    description = "Check the Galaxus persisted query hashes daily";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Populate shortly after boot, then once a day. The hashes survive weeks
      # at a time, so there is nothing to gain from checking more often.
      OnBootSec = "10min";
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  my.homelab.ports = [ mcpPort ];
}
