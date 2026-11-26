{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
  socket = "/run/hedgedoc/hedgedoc.sock";
  hedgedocDomain = "hedgedoc.${domain}";
in
{
  services.hedgedoc = {
    enable = true;
    settings = {
      # Group-writable through the module's UMask.
      path = socket;
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
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      extraConfig = ''
        rewrite ^/$ /homepage permanent;
      '';
      proxyPass = "http://unix:${socket}";
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

  services.restic.backups.daily.paths = [
    config.services.hedgedoc.settings.db.storage
    config.services.hedgedoc.settings.uploadsPath
  ];
  systemd.services.nginx.serviceConfig.SupplementaryGroups = [ "hedgedoc" ];
  #my.homelab.dashboard.Services.Notes.href = "https://${hedgedocDomain}";
}
