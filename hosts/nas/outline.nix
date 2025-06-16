{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  domain = "notes.${config.homelab.domain}";
in
{
  services.outline = {
    enable = true;
    port = 9281;
    forceHttps = false;
    publicUrl = "https://${domain}";
    storage.storageType = "local";
    oidcAuthentication = {
      clientId = "outline";
      clientSecretFile = config.age.secrets.outline-oidc-secret.path;
      authUrl = "https://auth.${config.homelab.domain}/api/oidc/authorization";
      tokenUrl = "https://auth.${config.homelab.domain}/api/oidc/token";
      userinfoUrl = "https://auth.${config.homelab.domain}/api/oidc/userinfo";
      usernameClaim = "preferred_username";
      displayName = "Authelia";
      scopes = [
        "openid"
        "offline_access"
        "profile"
        "email"
      ];
    };
  };
  services.nginx.virtualHosts."${domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    locations."/" = {
      proxyPass = "http://localhost:${toString config.services.outline.port}";
      proxyWebsockets = true;
    };
  };
  services.authelia.instances.main.settings.identity_providers.oidc.clients = [
    {
      client_id = "outline";
      client_secret = secrets.authelia-clients-outline;
      authorization_policy = "one_factor";
      redirect_uris = [
        "https://${domain}/auth/oidc.callback"
      ];
      scopes = [
        "openid"
        "offline_access"
        "profile"
        "email"
      ];
      token_endpoint_auth_method = "client_secret_post";
      consent_mode = "pre-configured";
    }
  ];

  # services.restic.backups.daily.paths = [
  #   config.services.hedgedoc.settings.db.storage
  #   config.services.hedgedoc.settings.uploadsPath
  # ];

  homelab.ports = [ config.services.outline.port ];
  homelab.dashboard.Services.Notes.href = "https://${domain}";
}
