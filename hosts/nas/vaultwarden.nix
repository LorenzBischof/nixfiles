{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
let
  domain = config.my.homelab.domain;
  vaultwardenDomain = "bitwarden.${domain}";
  backupDir = "/var/cache/vaultwarden-backup";
in
{
  services.vaultwarden = {
    enable = true;
    # TODO: this sets up a timer at 23:00, however it might make sense to run it before the backup service
    backupDir = backupDir;
    config = {
      DOMAIN = "https://${vaultwardenDomain}";
      SIGNUPS_ALLOWED = false;
      ROCKET_PORT = 8222;
    };
  };
  services.nginx.virtualHosts."${vaultwardenDomain}" = {
    forceSSL = true;
    useACMEHost = domain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.vaultwarden.config.ROCKET_PORT}";
      proxyWebsockets = true;
    };
  };

  # In addition to the timer also backup directly before the daily restic backup
  systemd.services.backup-vaultwarden.requiredBy = [ "restic-backups-daily.service" ];
  systemd.services.backup-vaultwarden.before = [ "restic-backups-daily.service" ];

  services.restic.backups.daily.paths = [ backupDir ];

  my.homelab.ports = [ config.services.vaultwarden.config.ROCKET_PORT ];
  my.homelab.dashboard.Services.Bitwarden.href = "https://${vaultwardenDomain}";
}
