{ pkgs, ... }:

let
  notify-send = "${pkgs.libnotify}/bin/notify-send";
in
{
  systemd.user.services.detect-syncthing-conflicts = {
    script = ''
      set -eu -o pipefail

      find /home/lbischof/files-lo -name '*sync-conflict*' | grep . && ${notify-send} "Syncthing conflict found in files-lo!" || true
      find /home/lbischof/files-tabi -name '*sync-conflict*' | grep . && ${notify-send} "Syncthing conflict found in files-tabi!" || true
    '';
    serviceConfig = {
      Type = "oneshot";
    };
  };
  systemd.user.timers.detect-syncthing-conflicts = {
    wantedBy = [ "timers.target" ];
    partOf = [ "detect-syncthing-conflicts.service" ];
    timerConfig = {
      OnCalendar = "hourly";
      Unit = "detect-syncthing-conflicts.service";
    };
  };
}
