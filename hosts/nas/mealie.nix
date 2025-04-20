{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  mealieDomain = "recipes.${config.homelab.domain}";
in
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

  services.nginx.virtualHosts."${mealieDomain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    locations."/" = {
      proxyPass = "http://localhost:${toString config.services.mealie.port}";
      proxyWebsockets = true;
    };
  };

  services.authelia.instances.main.settings.identity_providers.oidc = {
    claims_policies.mealie.id_token = [
      "email"
      "name"
    ];
    clients = [
      {
        client_id = "mealie";
        client_secret = secrets.authelia-clients-mealie;
        authorization_policy = "one_factor";
        redirect_uris = [
          "https://${mealieDomain}/login"
        ];
        consent_mode = "implicit";
        claims_policy = "mealie"; # https://www.authelia.com/integration/openid-connect/openid-connect-1.0-claims/#restore-functionality-prior-to-claims-parameter
      }
    ];
  };

  services.restic.backups.daily.paths = [ "/var/lib/mealie/mealie.db" ];
  homelab.ports = [ config.services.mealie.port ];
  homelab.dashboard.Services.Recipes.href = "https://${mealieDomain}";
}
