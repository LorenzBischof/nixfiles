{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:
{
  system.autoUpgrade = {
    # Disable if we have a dirty Git work tree
    enable = ((inputs.self.rev or "dirty") != "dirty");
    # Warning: if an unauthorized user has access to my account, they could escalate privileges.
    flake = "github:LorenzBischof/nixfiles";
    upgrade = false;
    randomizedDelaySec = "45m";
  };
  systemd.services = {
    nixos-upgrade = {
      onSuccess = [ "notify-upgrade-success.service" ];
      onFailure = [ "notify-upgrade-failure.service" ];
      # Check if the currently deployed revision exists on Github
      # Otherwise it could have been a manual switch --target-host
      # that is not pushed to Git yet and we do not want to downgrade
      serviceConfig.ExecCondition = ''
        ${pkgs.curl}/bin/curl --fail-with-body https://api.github.com/repos/lorenzbischof/nixfiles/commits/${inputs.self.rev or "dirty"}
      '';
      # Prefer not to autoupgrade when on battery
      unitConfig.ConditionACPower = true;
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
