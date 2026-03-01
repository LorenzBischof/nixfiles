{ pkgs, ... }:

{
  systemd.services.low-battery-power-button-led-blink = {
    description = "Blink power button LED";
    serviceConfig = {
      Type = "simple";
      Restart = "no";
    };
    script =
      let
        ectool = "${pkgs.fw-ectool}/bin/ectool";
      in
      ''
        set -eu

        trap '${ectool} led power auto' EXIT

        while true; do
          capacity="$(cat /sys/class/power_supply/BAT1/capacity)"
          status="$(cat /sys/class/power_supply/BAT1/status)"
          if [ "$status" != "Discharging" ] || [ "$capacity" -gt 9 ]; then
            exit 0
          fi

          ${ectool} led power off
          sleep 1
          ${ectool} led power auto
          sleep 1
        done
      '';
  };

  services.udev.extraRules = ''
    ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="BAT*", ATTR{status}=="Discharging", ATTR{capacity}=="[0-9]", TAG+="systemd", ENV{SYSTEMD_WANTS}+="low-battery-power-button-led-blink.service"
  '';
}
