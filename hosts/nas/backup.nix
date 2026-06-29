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

    pruneOpts = [
      "--group-by host"
      "--keep-daily 7"
      "--keep-weekly 5"
      "--keep-monthly 12"
      "--keep-yearly 3"
    ];

    createWrapper = false;
    runCheck = true;
    checkOpts = [ "--read-data-subset=10%" ];
  };

  services.prometheus.exporters.restic = {
    enable = true;
    repository = secrets.restic-repository;
    passwordFile = config.age.secrets.restic-password.path;
    environmentFile = config.age.secrets.restic-env.path;
    refreshInterval = 3600;
  };
  # nixpkgs still ships restic-exporter 1.7.0, which crash-loops against restic
  # 0.19.0: restic now prints a progress line to stdout even with --json, so the
  # exporter's json.loads() fails (ngosang/restic-exporter#60). Upstream fixed it
  # in 2.1.0, but the nixpkgs package has not been bumped (still 1.7.0 on
  # nixos-unstable as of 2026-06, no PR open). Override with our own 2.1.2 build.
  nixpkgs.overlays = [
    (final: _prev: {
      prometheus-restic-exporter = final.callPackage ../../packages/prometheus-restic-exporter.nix { };
    })
  ];

  systemd.services.prometheus-restic-exporter = {
    environment.NO_CHECK = "true";
    environment.INCLUDE_PATHS = "true";
    # Defense in depth: if the exporter ever fails, back off restarts (~1min to
    # 1h) so it can't hammer the B2 repo with `restic snapshots` every ~2min.
    serviceConfig = {
      RestartSec = "1min";
      RestartSteps = 6;
      RestartMaxDelaySec = "1h";
    };
  };

  services.restic.backups.daily.backupPrepareCommand =
    "${pkgs.curl}/bin/curl -fsS -m 10 --retry 5 -o /dev/null https://hc-ping.com/$HC_UUID/start";

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
