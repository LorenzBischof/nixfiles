{
  config,
  lib,
  secrets,
  ...
}:
let
  backupDir = "/var/cache/paperless-backup";
  domain = config.my.homelab.domain;
  paperlessDomain = "paperless.${domain}";
  socket = "/run/paperless-web/paperless.sock";
in
{
  services.paperless = {
    enable = true;
    passwordFile = config.age.secrets.paperless-password.path;
    settings = {
      PAPERLESS_ADMIN_USER = "paperless";
      PAPERLESS_AUTO_LOGIN_USERNAME = "paperless";
      PAPERLESS_OCR_LANGUAGE = "deu+eng";
      PAPERLESS_IGNORE_DATES = secrets.paperless-ignore-dates;
      PAPERLESS_CSRF_TRUSTED_ORIGINS = "https://${paperlessDomain}";
    };
  };
  # TODO: The module only takes a TCP address and port; granian reads the
  # socket from its environment and then ignores GRANIAN_HOST/GRANIAN_PORT.
  # No nixpkgs issue or PR as of 2026-11; drop this once the module has a
  # socket option.
  systemd.services.paperless-web = {
    environment = {
      GRANIAN_UDS = socket;
      GRANIAN_UDS_PERMISSIONS = "0660";
    };
    serviceConfig.RuntimeDirectory = "paperless-web";
  };
  systemd.services.nginx.serviceConfig.SupplementaryGroups = [ "paperless" ];
  # Every unit of it offline: it serves on the socket, keeps its database in
  # SQLite and imports no mail, and its workers OCR untrusted documents.
  my.services."system-paperless.slice" = { };

  services.nginx.virtualHosts."${paperlessDomain}" = {
    forceSSL = true;
    useACMEHost = domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://unix:${socket}";
      proxyWebsockets = true;
      enableAuthelia = true;
    };
  };

  systemd.tmpfiles.settings."10-paperless".${backupDir}.d = {
    inherit (config.services.paperless) user;
    mode = "0700";
  };

  systemd.services.paperless-backup =
    let
      cfg = config.systemd.services.paperless-consumer;
    in
    {
      description = "Paperless documents backup";
      serviceConfig = lib.recursiveUpdate cfg.serviceConfig {
        ExecStart = "${config.services.paperless.package}/bin/paperless-ngx document_exporter --no-archive --no-thumbnail --delete ${backupDir}";
        ReadWritePaths = cfg.serviceConfig.ReadWritePaths ++ [ backupDir ];
        Restart = "no";
        Type = "oneshot";
      };
      inherit (cfg) environment;
      requiredBy = [ "restic-backups-daily.service" ];
      before = [ "restic-backups-daily.service" ];
    };
  services.restic.backups.daily.paths = [ backupDir ];

  my.homelab.dashboard.Services.Paperless.href = "https://${paperlessDomain}";

}
