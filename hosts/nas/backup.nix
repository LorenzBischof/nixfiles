{
  config,
  pkgs,
  lib,
  secrets,
  ...
}:
{
  services.restic.backups.daily = {
    initialize = true;
    environmentFile = config.age.secrets.restic-env.path;
    repositoryFile = lib.mkDefault config.age.secrets.restic-repo.path;
    passwordFile = config.age.secrets.restic-password.path;

    timerConfig.OnCalendar = "10:00";
  };
  services.restic.backups.weekly = {
    environmentFile = config.age.secrets.restic-env.path;
    repositoryFile = lib.mkDefault config.age.secrets.restic-repo.path;
    passwordFile = config.age.secrets.restic-password.path;

    timerConfig.OnCalendar = "Mon 14:00";

    paths = null; # disable backup
    createWrapper = false;
    runCheck = true;
  };

  services.prometheus.exporters.restic = {
    enable = true;
    repository = secrets.restic-repository;
    passwordFile = config.age.secrets.restic-password.path;
    environmentFile = config.age.secrets.restic-env.path;
    refreshInterval = 3600;
  };
  systemd.services.prometheus-restic-exporter = {
    environment.NO_CHECK = "true";
    # The exporter crash-loops on restic 0.19.0 (ngosang/restic-exporter#60), and
    # Restart=always re-runs `restic snapshots` against B2 every ~2min, draining the
    # download cap. Back off so a crash can't hammer the repo: ~1min to 1h.
    serviceConfig = {
      RestartSec = "1min";
      RestartSteps = 6;
      RestartMaxDelaySec = "1h";
    };
  };

  services.restic.backups.daily.backupPrepareCommand = "${pkgs.curl}/bin/curl -fsS -m 10 --retry 5 -o /dev/null https://hc-ping.com/$HC_UUID/start";

  systemd.services."restic-backups-daily" = {
    onSuccess = [ "restic-notify-daily@success.service" ];
    onFailure = [ "restic-notify-daily@failure.service" ];
  };

  systemd.services."restic-notify-daily@" = {
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = config.age.secrets.restic-env.path; # contains heathchecks.io UUID
      ExecStart = "${pkgs.curl}/bin/curl -fsS -m 10 --retry 5 -o /dev/null https://hc-ping.com/\${HC_UUID}/\${MONITOR_EXIT_STATUS}";
    };
  };
}
