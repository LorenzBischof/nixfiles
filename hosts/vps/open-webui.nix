{
  config,
  lib,
  ...
}:
let
  domain = config.my.homelab.domain;
  chatDomain = "chat.${domain}";

  port = 8090;

  authSocket = config.services.tailscaleAuth.socketPath;

  # MCP servers already running on this host (cooklang.nix, galaxus.nix),
  # reached directly over loopback - see mcp.nix. An empty `access_grants`
  # would make a connection admin-only, hence the grant to every user. `path`
  # and `key` go unused for MCP, but the admin panel's schema requires both.
  mcpServer = id: name: mcpPort: {
    type = "mcp";
    url = "http://127.0.0.1:${mcpPort}/mcp";
    path = "";
    auth_type = "none";
    key = "";
    config = {
      enable = true;
      access_grants = [
        {
          principal_type = "user";
          principal_id = "*";
          permission = "read";
        }
      ];
    };
    info = {
      inherit id name;
      description = "";
    };
  };
in
{
  services.open-webui = {
    enable = true;
    host = "127.0.0.1";
    inherit port;
    environment = {
      WEBUI_URL = "https://${chatDomain}";
      # The default is `*` with credentials allowed. Identity comes from the
      # visitor's tailnet address, not a cookie, so any page a tailnet user
      # opens could otherwise sign in as them and read the token back.
      CORS_ALLOW_ORIGIN = "https://${chatDomain}";

      # Sign-in is the tailnet's: nginx asks tailscaled who owns the device a
      # request comes from and passes that login on. Open WebUI creates an
      # account for each new login on its first visit - the first one becomes
      # admin.
      WEBUI_AUTH_TRUSTED_EMAIL_HEADER = "X-Webauth-Login";
      WEBUI_AUTH_TRUSTED_NAME_HEADER = "X-Webauth-Name";
      # Not "pending", the default, which would leave everyone after the first
      # account waiting for an admin to let them in.
      DEFAULT_USER_ROLE = "user";
      # Leave ENABLE_PASSWORD_AUTH alone: in 0.13.3, turning it off makes
      # /signin refuse every request before it looks at the trusted header.

      ENABLE_OLLAMA_API = "False";

      # Seeds the admin settings on first start only: Open WebUI keeps its
      # config in its database afterwards, and changes made in the admin panel
      # win over these.
      TOOL_SERVER_CONNECTIONS = builtins.toJSON [
        (mcpServer "galaxus" "Galaxus" config.systemd.services.galaxus-mcp.environment.GALAXUS_MCP_PORT)
        (mcpServer "mealplanner" "Mealplanner"
          config.systemd.services.cooklang-mcp.environment.COOKLANG_MCP_PORT
        )
      ];

      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
    };
  };

  # The trusted header is only as trustworthy as whoever can reach the port, and
  # every process here can reach loopback - the agents included. So only nginx,
  # which only ever sends a login tailscaled vouched for, may connect to it.
  my.services.open-webui = {
    ports = [ port ];
    clients = [ "nginx" ];
    # The model providers are on the internet.
    internet = true;
  };

  # The helper only, not `services.nginx.tailscaleAuth`: that one puts its
  # subrequest at `/auth`, which is a page of Open WebUI's own, so reloading it
  # would 404. It refuses tagged devices - this host is `tag:server`, so the
  # agents here cannot sign in as anyone by going through nginx either.
  services.tailscaleAuth.enable = true;
  users.users.${config.services.nginx.user}.extraGroups = [ config.services.tailscaleAuth.group ];

  # Tailnet only: no listen address of its own.
  services.nginx.virtualHosts.${chatDomain} = {
    forceSSL = true;
    useACMEHost = domain;
    extraConfig = ''
      # This host's own processes, the agents included, arrive from its tailnet
      # address. Tailscale refuses them too while this node is tagged, but that
      # lives in the admin console, not here.
      ${lib.concatMapStrings (a: "deny ${a};\n") config.services.nginx.defaultListenAddresses}
      allow all;

      # Uploads to chats and knowledge.
      client_max_body_size 100m;

      # Any page a tailnet user opens could frame this UI, signed in as them by
      # the trusted header, and trick them into clicking. Open WebUI sends no
      # framing headers of its own unless configured.
      add_header X-Frame-Options DENY always;
      add_header Content-Security-Policy "frame-ancestors 'none'" always;
    '';
    locations = {
      "/" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        proxyWebsockets = true;
        extraConfig = ''
          # Replies stream as SSE and must not be buffered.
          proxy_buffering off;
          proxy_read_timeout 600s;

          auth_request /_tailscale_auth;
          # Tailscale-User, the whole login. Tailscale-Login is only the part
          # before the @, so alice@github and alice@gmail.com would share an
          # account.
          auth_request_set $ts_login $upstream_http_tailscale_user;
          auth_request_set $ts_name $upstream_http_tailscale_name;
          # Set even when empty: an empty value drops the header rather than
          # letting a client's own copy through.
          proxy_set_header X-Webauth-Login $ts_login;
          proxy_set_header X-Webauth-Name $ts_name;
        '';
      };

      # The helper looks the caller up by address and port alone.
      "= /_tailscale_auth".extraConfig = ''
        internal;
        proxy_pass http://unix:${authSocket};
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Remote-Addr $remote_addr;
        proxy_set_header Remote-Port $remote_port;
      '';
    };
  };
}
