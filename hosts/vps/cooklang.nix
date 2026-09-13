{
  config,
  pkgs,
  ...
}:
let
  domain = config.my.homelab.domain;
  mcpDomain = "meals.${domain}";
  # `recipes.${domain}` is already Mealie on nas, so the browser UI gets its own
  # name rather than colliding with it.
  uiDomain = "cook.${domain}";

  stateDir = "/var/lib/cooklang";
  collection = "${stateDir}/collection";

  mcpPort = 3001;
  uiPort = 9080;

  cooklang-mcp = pkgs.callPackage ../../packages/cooklang-mcp { };
  cook-cli-server = pkgs.callPackage ../../packages/cook-cli-server.nix { };
  cook-cli-manifest = pkgs.runCommand "cook-cli-site.webmanifest" { } ''
    cp ${cook-cli-server.src}/static/site.webmanifest $out
    substituteInPlace $out \
      --replace-fail '"theme_color": "#f97316"' '"theme_color": "#18181b"'
  '';

  # A static user, deliberately not DynamicUser: `cook server` owns the
  # collection and the shopping list it keeps beside it, and a per-activation
  # UID would make that ownership unusable.
  user = "cooklang";
in
{
  users.users.${user} = {
    isSystemUser = true;
    group = user;
    home = stateDir;
  };
  users.groups.${user} = { };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 ${user} ${user} -"
    "d ${collection} 0750 ${user} ${user} -"
    "d ${collection}/config 0750 ${user} ${user} -"
  ];

  # The recipe collection, and the only thing that touches it. Both the browser
  # UI and the MCP server below are clients of this one process, so they always
  # see the same recipes, the same pantry and the same shopping list.
  #
  # It has no authentication of its own, which is why its vhost never gains a
  # public listen address.
  systemd.services.cook-server = {
    description = "Cooklang recipe server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${cook-cli-server}/bin/cook server --port ${toString uiPort} ${collection}";
      User = user;
      Group = user;
      WorkingDirectory = collection;
      Restart = "on-failure";
      RestartSec = "5s";

      ReadWritePaths = [ collection ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  systemd.services.cooklang-mcp = {
    description = "Cooklang MCP server";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "cook-server.service"
    ];
    # Every tool but `fetch_recipe` is a call to cook-server; without it the
    # server answers, but answers nothing but errors.
    wants = [ "cook-server.service" ];
    # LoadCredential snapshots the token once, at start, and the unit text does
    # not change when the secret is rekeyed - so nothing restarts this and the
    # server keeps checking against a stale token. Every request then fails the
    # bearer check and claude.ai sees the 404 below, with nothing in the log to
    # say why. Tie the unit to the encrypted file so a rekey restarts it.
    restartTriggers = [ config.age.secrets.cooklang-mcp-token.file ];
    environment = {
      COOKLANG_SERVER_URL = "http://127.0.0.1:${toString uiPort}";
      COOKLANG_WEB_URL = "https://${uiDomain}";
      COOKLANG_MCP_TRANSPORT = "http";
      COOKLANG_MCP_PORT = toString mcpPort;
      # The shared bearer token, placed here by LoadCredential below.
      COOKLANG_MCP_TOKEN_FILE = "%d/token";
    };
    serviceConfig = {
      ExecStart = "${cooklang-mcp}/bin/cooklang-mcp";
      LoadCredential = "token:${config.age.secrets.cooklang-mcp-token.path}";
      Restart = "on-failure";
      RestartSec = "5s";

      # It reads and writes nothing on disk: the recipes reach it over HTTP
      # from cook-server, so it needs no identity of its own.
      DynamicUser = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  # Publicly reachable, because claude.ai connects from the internet. Same
  # pattern as the n8n webhook vhost: nginx listens on the tailnet by default
  # and a vhost opts in to the public NIC.
  services.nginx.virtualHosts."${mcpDomain}" = {
    forceSSL = true;
    useACMEHost = domain;
    listenAddresses = [ "10.0.0.238" ] ++ config.services.nginx.defaultListenAddresses;
    # An exact match, so widening this later cannot publish anything else.
    locations."= /mcp" = {
      proxyPass = "http://127.0.0.1:${toString mcpPort}";
      extraConfig = ''
        # Anthropic's documented egress range. The bearer token guards against a
        # leaked URL; this guards against everyone else.
        allow 160.79.104.0/21;
        deny all;
        # Streamable HTTP responses are SSE and must not be buffered.
        proxy_buffering off;
      '';
    };
  };

  # Tailnet only: no extra listen address.
  services.nginx.virtualHosts."${uiDomain}" = {
    forceSSL = true;
    useACMEHost = domain;
    # cookcli embeds its static files in the Rust binary. Override only the
    # themed assets at the proxy so edits require an nginx reload, not a Rust
    # build. Generate the manifest from upstream so new PWA metadata is retained.
    locations."= /static/css/custom-styles.css".alias = ../../packages/cook-cli-theme.css;
    locations."= /static/site.webmanifest".alias = cook-cli-manifest;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString uiPort}";
      proxyWebsockets = true;
    };
  };

  my.homelab.ports = [
    mcpPort
    uiPort
  ];
}
