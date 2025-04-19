{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  hedgedocDomain = "notes.${config.homelab.domain}";
in
{
  services.hedgedoc = {
    enable = true;
    settings = {
      port = 52918;
      domain = hedgedocDomain;
      email = false;
      allowAnonymous = true;
      allowAnonymousEdits = true;
      defaultPermission = "freely";
      allowFreeURL = true;
      protocolUseSSL = true;
      useSSL = false;
      sessionLife = 24 * 60 * 60 * 1000 * 365;
    };
    environmentFile = config.age.secrets.hedgedoc-env.path;
  };
  services.nginx.virtualHosts."${hedgedocDomain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      extraConfig = ''
        rewrite ^/$ /homepage permanent;
      '';
      proxyPass = "http://localhost:${toString config.services.hedgedoc.settings.port}";
      proxyWebsockets = true;
      enableAuthelia = true;
    };
  };
  services.authelia.instances.main.settings.identity_providers.oidc.clients = [
    {
      client_id = "hedgedoc";
      client_secret = secrets.authelia-clients-hedgedoc;
      authorization_policy = "one_factor";
      redirect_uris = [
        "https://${hedgedocDomain}/auth/oauth2/callback"
      ];
      token_endpoint_auth_method = "client_secret_post";
      consent_mode = "implicit";
    }
  ];

  homelab.ports = [ config.services.hedgedoc.settings.port ];
  homelab.dashboard.Monitoring.Hedgedoc.href = "https://${hedgedocDomain}";
}
