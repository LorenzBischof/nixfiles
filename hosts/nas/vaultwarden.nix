{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  backupDir = "/var/cache/vaultwarden-backup";
in
{
  services.vaultwarden = {
    enable = true;
    # TODO: this sets up a timer at 23:00, however it might make sense to run it before the backup service
    backupDir = backupDir;
    config = {
      DOMAIN = "https://bitwarden.${config.homelab.domain}";
      SIGNUPS_ALLOWED = false;
      ROCKET_PORT = 8222;
    };
  };
  services.nginx.virtualHosts."bitwarden.${config.homelab.domain}" = {
    forceSSL = true;
    useACMEHost = config.homelab.domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.vaultwarden.config.ROCKET_PORT}";
      proxyWebsockets = true;
    };
  };

  # In addition to the timer also backup directly before the daily restic backup
  systemd.services.backup-vaultwarden.requiredBy = [ "restic-backups-daily.service" ];
  systemd.services.backup-vaultwarden.before = [ "restic-backups-daily.service" ];

  services.restic.backups.daily.paths = [ backupDir ];

  homelab.ports = [ config.services.vaultwarden.config.ROCKET_PORT ];
  homelab.dashboard.Services.Vaultwarden.href = "https://bitwarden.${config.homelab.domain}";
}
