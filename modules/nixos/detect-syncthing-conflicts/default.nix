{
  pkgs,
  lib,
  config,
  ...
}:

let
  cfg = config.my.services.detect-syncthing-conflicts;
  notify-send = "${pkgs.libnotify}/bin/notify-send";
  syncthing-resolve-conflict = pkgs.writeShellApplication {
    name = "syncthing-resolve-conflict";
    runtimeInputs = [ pkgs.file ];
    text = builtins.readFile ./syncthing-resolve-conflict;
  };
in
{
  options.my.services.detect-syncthing-conflicts.enable =
    lib.mkEnableOption "detect syncthing conflicts";
  config = lib.mkIf cfg.enable {

    environment.systemPackages = [
      syncthing-resolve-conflict
    ];
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
  };
}
