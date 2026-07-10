{
  pkgs,
  lib,
  config,
  ...
}:

{
  my.system.autoUpgrade = {
    enable = true;
    dates = "hourly";
    flake = "github:LorenzBischof/nixfiles";
  };

  systemd.services = lib.mkIf config.my.system.autoUpgrade.enabled {
    nixos-upgrade = {
      onSuccess = [ "notify-upgrade-success.service" ];
      onFailure = [ "notify-upgrade-failure.service" ];

      # ExecStartPre runs only after the module's ExecCondition passes, i.e. only
      # when a real upgrade is about to build (not on the hourly no-op check).
      # --no-block so it never delays the upgrade; "-" so a failed notify is
      # ignored. Appends to the start-metric ExecStartPre defined in the module.
      serviceConfig.ExecStartPre = [
        "-${config.systemd.package}/bin/systemctl start --no-block notify-upgrade-start.service"
      ];
    };
    "notify-upgrade-start" = {
      serviceConfig.User = "lbischof";
      # The variable %U does not seem to work
      environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
      script = ''
        ${pkgs.libnotify}/bin/notify-send "Auto upgrade started"
      '';
    };
    "notify-upgrade-success" = {
      serviceConfig.User = "lbischof";
      # The variable %U does not seem to work
      environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
      script = ''
        # OnSuccess fires both for a real upgrade and for an ExecCondition skip
        # (a battery skip never reaches us: ConditionACPower stops the unit
        # first, so OnSuccess= never triggers -- see modules/nixos/autoupgrade.nix).
        # The ExecCondition exit status alone distinguishes the outcomes and
        # encodes the skip reason: 0 = upgraded, 1 = already up to date (silent),
        # 2/3/4 = a repo/remote mismatch that needs action.
        cond="$(systemctl show nixos-upgrade -p ExecCondition --value)"
        status="''${cond##*status=}"
        status="''${status%%[!0-9]*}"
        case "$status" in
          0) ${pkgs.libnotify}/bin/notify-send "Auto upgrade success" ;;
          2) ${pkgs.libnotify}/bin/notify-send --urgency=critical "Auto upgrade skipped" "Commit is ahead of the default branch. Did you merge your PR?" ;;
          3) ${pkgs.libnotify}/bin/notify-send --urgency=critical "Auto upgrade skipped" "Commit does not exist on the remote. Did you push your changes?" ;;
          4) ${pkgs.libnotify}/bin/notify-send --urgency=critical "Auto upgrade skipped" "Could not reach GitHub. Maybe you are rate-limited?" ;;
        esac
      '';
    };

    "notify-upgrade-failure" = {
      serviceConfig.User = "lbischof";
      # The variable %U does not seem to work
      environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
      script = ''
        ${pkgs.libnotify}/bin/notify-send --urgency=critical "Auto upgrade failure!"
      '';
    };
  };
}
