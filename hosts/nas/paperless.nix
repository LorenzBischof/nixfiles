{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  backupDir = "/var/cache/paperless-backup";
  paperlessDomain = "paperless.${config.homelab.domain}";
in
{
  services.paperless = {
    # https://github.com/NixOS/nixpkgs/issues/421393
    package = pkgs.paperless-ngx.overrideAttrs (oldAttrs: {
      doCheck = false;
    });
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
  services.nginx.virtualHosts."${paperlessDomain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    enableAuthelia = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.paperless.port}";
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

  homelab.ports = [ config.services.paperless.port ];
  homelab.dashboard.Services.Paperless.href = "https://${paperlessDomain}";

}
