{
  pkgs,
  config,
  lib,
  ...
}:

let
  readlink = "${pkgs.coreutils}/bin/readlink";
  notify-send = "${pkgs.libnotify}/bin/notify-send";
  cfg = config.my.services.detect-reboot-required;
in
{
  options.my.services.detect-reboot-required.enable = lib.mkEnableOption "detect-reboot-required";
  config = lib.mkIf cfg.enable {
    systemd.user.services.detect-reboot-required = {
      script = ''
        set -eu -o pipefail

        booted="$(${readlink} /run/booted-system/{initrd,kernel,kernel-modules})"
        built="$(${readlink} /nix/var/nix/profiles/system/{initrd,kernel,kernel-modules})"

        if [[ "''${booted}" != "''${built}" ]];
        then
          echo "Looks like we need a reboot!"
          ${notify-send} --urgency=low --icon=system-reboot "Reboot is needed for a NixOS upgrade."
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
      };
    };
    systemd.user.timers.detect-reboot-required = {
      wantedBy = [ "timers.target" ];
      partOf = [ "detect-reboot-required.service" ];
      timerConfig = {
        OnCalendar = "hourly";
        Unit = "detect-reboot-required.service";
      };
    };
  };
}
