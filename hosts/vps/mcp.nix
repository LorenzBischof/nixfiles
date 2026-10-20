{
  config,
  lib,
  ...
}:
let
  domain = config.my.homelab.domain;
in
{
  # One pair of names for every MCP server here: each service file adds its own
  # `locations."= /<name>"` to both, so a new server needs no DNS record, cert
  # change or nginx block. Auth is a property of the name, not the server - the
  # servers bind loopback with no auth of their own, so the public name carries
  # the token check and the tailnet name needs none.
  #
  # `listenAddresses` is a list and would concatenate into duplicate `listen`
  # directives, so the vhosts are opened once here and left otherwise empty.

  # The only name needing an explicit A record - `*.<domain>` points at the
  # tailnet address instead.
  services.nginx.virtualHosts."mcp.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    listenAddresses = [ "10.0.0.238" ] ++ config.services.nginx.defaultListenAddresses;
    extraConfig = ''
      # Anthropic's documented egress range, shared by all their egress - so it
      # cannot tell this account from any other.
      allow 160.79.104.0/21;
      deny all;

      # `auth_request`, not a server-level `if ($mcpAuthorized = 0)`: an `if`
      # returns in the rewrite phase, ahead of both preaccess (`limit_req`) and
      # access (the allow/deny above), which would leave the limiter never
      # seeing a failed attempt and the egress range not gating the token.
      limit_req zone=mcpauth burst=5 nodelay;
      # A refused attempt is the client's rate, not this server being down.
      limit_req_status 429;
      auth_request /_mcp_auth;

      # In extraConfig, not `locations`: the tailnet vhost copies `locations`
      # wholesale and has no auth_request to call this one.
      location = /_mcp_auth {
        internal;
        if ($mcpAuthorized = 0) {
          return 401;
        }
        return 204;
      }
    '';
  };

  # Only the token's value lives in the secret - a single `"Bearer <token>" 1;`
  # entry - because a header value has to be literal and nginx.conf is
  # world-readable in /nix/store.
  services.nginx.appendHttpConfig = ''
    map $http_authorization $mcpAuthorized {
      default 0;
      include ${config.age.secrets.mcp-nginx-auth.path};
    }

    # Why a legitimate session never meets the limiter: nginx does not account a
    # request whose key is empty, so only failures spend the budget.
    map $mcpAuthorized $mcpUnauthorizedClient {
      1 "";
      default $binary_remote_addr;
    }

    # Per address, so one source cannot spend another's. The rate bounds
    # guessing only - the token's entropy is what makes it unguessable.
    limit_req_zone $mcpUnauthorizedClient zone=mcpauth:1m rate=10r/m;
  '';

  # The key is the whole header value, `Bearer ` + a 64-char token = 71 chars,
  # needing 96 bytes of bucket against a default of the CPU cache line (64
  # here); too small and nginx refuses to start. The module option and not a
  # directive in `appendHttpConfig`, because it must precede every map:
  # `ngx_http_map_block` reads the value while parsing a map, a map parsed while
  # it is unset sets it itself - after which the directive is rejected as "is
  # duplicate" - and the module renders its own `$connection_upgrade` map first.
  services.nginx.mapHashBucketSize = 128;

  # nginx's master runs as `nginx`, so agenix's default 0400 root:root leaves the
  # secret unreadable to the process that parses it. The `keys` group would not
  # help: it grants r-x on the directory, but the file is owner-only.
  age.secrets.mcp-nginx-auth.owner = "nginx";

  # A rekey does not change nginx's unit text, so nothing would reload it.
  systemd.services.nginx.restartTriggers = [ config.age.secrets.mcp-nginx-auth.file ];

  # The same servers for agents on the tailnet. No listen address of its own, so
  # it answers only on the tailnet address from configuration.nix - that address
  # is the entire access control, hence no allow/deny and no token.
  services.nginx.virtualHosts."mcp-tnet.${domain}" = {
    forceSSL = true;
    useACMEHost = domain;
    # Copied wholesale, so a service file states its path and port once.
    # `_module` is submodule bookkeeping, not an option to set again.
    locations = lib.mapAttrs (
      _: location: removeAttrs location [ "_module" ]
    ) config.services.nginx.virtualHosts."mcp.${domain}".locations;
  };
}
