{ pkgs, lib, ... }:

{
  my.system.autoUpgrade = {
    enable = true;
    dates = "hourly";
    flake = "github:LorenzBischof/nixfiles";
  };

  systemd.services = {
    nixos-upgrade = {
      onSuccess = [ "notify-upgrade-success.service" ];
      onFailure = [ "notify-upgrade-failure.service" ];

    };
    "notify-upgrade-success" = {
      serviceConfig.User = "lbischof";
      # The variable %U does not seem to work
      environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
      script = ''
        if [ "$(systemctl show nixos-upgrade -p ConditionResult --value)" = "no" ]; then
          ${pkgs.libnotify}/bin/notify-send "Auto upgrade skipped"
        else
          ${pkgs.libnotify}/bin/notify-send "Auto upgrade success"
        fi
      '';
    };

    "notify-upgrade-failure" = {
      serviceConfig.User = "lbischof";
      # The variable %U does not seem to work
      environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
      script = ''
        ${pkgs.libnotify}/bin/notify-send --urgency=critical "Auto upgrade failure!";
      '';
    };
  };
}
