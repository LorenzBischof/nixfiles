{
  config,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
  dawarichDomain = "dawarich.${domain}";
in
{
  services.dawarich = {
    enable = true;
    localDomain = dawarichDomain;
    configureNginx = true;
    webPort = 19237;
    environment = {
      OIDC_ENABLED = "true";
      OIDC_ISSUER = "https://auth.${domain}";
      OIDC_CLIENT_ID = "dawarich";
      OIDC_REDIRECT_URI = "https://${dawarichDomain}/users/auth/openid_connect/callback";
      OIDC_PROVIDER_NAME = "Authelia";
      OIDC_AUTO_REGISTER = "true";
      ALLOW_EMAIL_PASSWORD_REGISTRATION = "false";
    };
    extraEnvFiles = [ config.age.secrets.dawarich-oidc-env.path ];
  };

  services.nginx.virtualHosts."${dawarichDomain}" = {
    useACMEHost = domain;
    forceSSL = true;
  };

  services.authelia.instances.main.settings.identity_providers.oidc.clients = [
    {
      client_id = "dawarich";
      client_secret = secrets.authelia-clients-dawarich;
      authorization_policy = "one_factor";
      redirect_uris = [
        "https://${dawarichDomain}/users/auth/openid_connect/callback"
      ];
      scopes = [
        "openid"
        "email"
        "profile"
      ];
      consent_mode = "implicit";
    }
  ];

  my.homelab.ports = [ config.services.dawarich.webPort ];
  my.homelab.dashboard.Services.Dawarich.href = "https://${dawarichDomain}";
}
