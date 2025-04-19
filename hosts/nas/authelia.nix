{
  config,
  lib,
  pkgs,
  secrets,
  ...
}:
let
  inherit (config.homelab) domain;
  autheliaLocation = pkgs.writeText "authelia-location.conf" ''
    ## Essential Proxy Configuration
    internal;
    proxy_pass http://localhost:9091/api/verify;
    ## Headers
    ## The headers starting with X-* are required.
    proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
    proxy_set_header X-Original-Method $request_method;
    proxy_set_header X-Forwarded-Method $request_method;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header Content-Length "";
    proxy_set_header Connection "";
    ## Basic Proxy Configuration
    proxy_pass_request_body off;
    proxy_next_upstream error timeout invalid_header http_500 http_502 http_503; # Timeout if the real server is dead
    proxy_redirect http:// $scheme://;
    proxy_http_version 1.1;
    proxy_cache_bypass $cookie_session;
    proxy_no_cache $cookie_session;
    proxy_buffers 4 32k;
    client_body_buffer_size 128k;
    ## Advanced Proxy Configuration
    send_timeout 5m;
    proxy_read_timeout 240;
    proxy_send_timeout 240;
    proxy_connect_timeout 240;
  '';
  autheliaRequest = pkgs.writeText "authelia-authrequest.conf" ''
    ### goes inside a location block to make the request to authelia
    ## Send a subrequest to Authelia to verify if the user is authenticated and has permission to access the resource.
    auth_request /authelia;
    ## Set the $target_url variable based on the original request.
    ## Comment this line if you're using nginx without the http_set_misc module.
    #set_escape_uri $target_url $scheme://$http_host$request_uri;
    ## Uncomment this line if you're using NGINX without the http_set_misc module.
    set $target_url $scheme://$http_host$request_uri;
    ## Save the upstream response headers from Authelia to variables.
    auth_request_set $user $upstream_http_remote_user;
    auth_request_set $groups $upstream_http_remote_groups;
    auth_request_set $name $upstream_http_remote_name;
    auth_request_set $email $upstream_http_remote_email;
    ## Inject the response headers from the variables into the request made to the backend.
    proxy_set_header Remote-User $user;
    proxy_set_header Remote-Groups $groups;
    proxy_set_header Remote-Name $name;
    proxy_set_header Remote-Email $email;
        ## If the subreqest returns 200 pass to the backend, if the subrequest returns 401 redirect to the portal.
    error_page 401 =302 https://auth.${domain}/?rd=$target_url;
  '';
  vhostOptions =
    { config, ... }:
    {
      options = {
        enableAuthelia = lib.mkEnableOption "Enable authelia";
        locations = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule locationOptions);
        };
      };
      config = lib.mkIf config.enableAuthelia {
        locations."/authelia" = {
          extraConfig = ''
            include ${autheliaLocation};
          '';
        };
        # Sadly I did not figure out how to avoid infinite recursion
        #(lib.mapAttrs (name: locationConfig:
        #    lib.mkIf (name != "/authelia") {
        #    extraConfig = ''
        #      include ${autheliaRequest};
        #    '';
        #    }
        #  ) config.locations)
      };
    };
  locationOptions =
    { config, ... }:
    {
      options = {
        enableAuthelia = lib.mkEnableOption "Enable authelia";
      };
      config = lib.mkIf config.enableAuthelia {
        extraConfig = ''
          include ${autheliaRequest};
        '';
      };
    };

in
{
  options.services.nginx.virtualHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule vhostOptions);
  };
  config = {
    services.authelia.instances.main = {
      enable = true;
      secrets = {
        jwtSecretFile = config.age.secrets.authelia-jwt-secret.path;
        storageEncryptionKeyFile = config.age.secrets.authelia-storage-encryption-key.path;
        sessionSecretFile = config.age.secrets.authelia-session-secret.path;
        oidcIssuerPrivateKeyFile = config.age.secrets.authelia-oidc-key.path;
        oidcHmacSecretFile = config.age.secrets.authelia-oidc-hmac.path;
      };
      settings = {
        log.level = "info";
        authentication_backend.file.path = config.age.secrets.authelia-users.path;
        access_control.default_policy = "one_factor";
        session.cookies = [
          {
            domain = domain;
            authelia_url = "https://auth.${domain}";
          }
        ];
        session.redis.host = config.services.redis.servers.authelia-main.unixSocket;
        storage.local.path = "/var/lib/authelia-main/db.sqlite3";
        notifier.filesystem.filename = "/var/lib/authelia-main/notification.txt";
        identity_providers.oidc = {
          claims_policies.default.id_token = [
            "email"
            "name"
          ];
          clients = [
            {
              client_id = "audiobookshelf";
              client_secret = secrets.authelia-clients-audiobookshelf;
              authorization_policy = "one_factor";
              redirect_uris = [
                "https://audiobookshelf.${domain}/auth/openid/callback"
                "https://audiobookshelf.${domain}/auth/openid/mobile-redirect"
                "audiobookshelf://oauth"
              ];
              consent_mode = "implicit";
            }
            {
              client_id = "mealie";
              client_secret = secrets.authelia-clients-mealie;
              authorization_policy = "one_factor";
              redirect_uris = [
                "https://mealie.${domain}/login"
              ];
              consent_mode = "implicit";
              claims_policy = "default"; # https://www.authelia.com/integration/openid-connect/openid-connect-1.0-claims/#restore-functionality-prior-to-claims-parameter
            }
            {
              client_id = "hedgedoc";
              client_secret = secrets.authelia-clients-hedgedoc;
              authorization_policy = "one_factor";
              redirect_uris = [
                "https://hedgedoc.${domain}/auth/oauth2/callback"
              ];
              grant_types = [
                "refresh_token"
                "authorization_code"
              ];
              token_endpoint_auth_method = "client_secret_post";
              consent_mode = "implicit";
            }
          ];
        };
      };
    };
    services.redis.servers.authelia-main = {
      enable = true;
      user = "authelia-main";
    };
    homelab.ports = [ 9091 ];
    services.nginx.virtualHosts."auth.${domain}" = {
      forceSSL = true;
      useACMEHost = domain;
      locations."/" = {
        proxyPass = "http://127.0.0.1:9091";
        proxyWebsockets = true;
      };
    };
  };
}
