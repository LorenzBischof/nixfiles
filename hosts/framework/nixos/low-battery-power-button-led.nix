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
          # Read with the builtin rather than cat: this loop runs up to ten
          # times a second on a nearly empty battery.
          read -r capacity < /sys/class/power_supply/BAT1/capacity
          read -r status < /sys/class/power_supply/BAT1/status
          if [ "$status" != "Discharging" ] || [ "$capacity" -gt 9 ]; then
            exit 0
          fi

          # Blink faster the emptier the battery gets: 0.8s per phase at 9%
          # down to 0.1s at 2% and below.
          half_period="$((capacity - 1))"
          if [ "$half_period" -lt 1 ]; then
            half_period=1
          fi
          half_period="$((half_period / 10)).$((half_period % 10))"

          ${ectool} led power off
          sleep "$half_period"
          ${ectool} led power auto
          sleep "$half_period"
        done
      '';
  };

  services.udev.extraRules = ''
    ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="BAT*", ATTR{status}=="Discharging", ATTR{capacity}=="[0-9]", TAG+="systemd", ENV{SYSTEMD_WANTS}+="low-battery-power-button-led-blink.service"
  '';
}
