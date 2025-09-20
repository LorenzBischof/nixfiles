{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
  outlineDomain = "notes.${domain}";
in
{
  services.outline = {
    enable = true;
    port = 9281;
    forceHttps = false;
    publicUrl = "https://${outlineDomain}";
    storage.storageType = "local";
    oidcAuthentication = {
      clientId = "outline";
      clientSecretFile = config.age.secrets.outline-oidc-secret.path;
      authUrl = "https://auth.${domain}/api/oidc/authorization";
      tokenUrl = "https://auth.${domain}/api/oidc/token";
      userinfoUrl = "https://auth.${domain}/api/oidc/userinfo";
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
  services.nginx.virtualHosts."${outlineDomain}" = {
    forceSSL = true;
    useACMEHost = domain;
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
        "https://${outlineDomain}/auth/oidc.callback"
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

  my.homelab.ports = [ config.services.outline.port ];
  my.homelab.dashboard.Services.Notes.href = "https://${outlineDomain}";
}
