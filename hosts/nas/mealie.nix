{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{
  services.mealie = {
    enable = true;
    settings = {
      OIDC_AUTH_ENABLED = "true";
      OIDC_SIGNUP_ENABLED = "true";
      OIDC_CONFIGURATION_URL = "https://auth.${config.homelab.domain}/.well-known/openid-configuration";
      OIDC_CLIENT_ID = "mealie";
      OIDC_AUTO_REDIRECT = "true"; # WARNING: a default local admin user is created by default!
    };
    credentialsFile = config.age.secrets.mealie-credentials.path;
  };
  services.nginx.virtualHosts."mealie.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    locations."/" = {
      proxyPass = "http://localhost:${toString config.services.mealie.port}";
      proxyWebsockets = true;
    };
  };

  homelab.ports = [ config.services.mealie.port ];
  homelab.dashboard.Services.Mealie.href = "https://mealie.${config.homelab.domain}";
}
