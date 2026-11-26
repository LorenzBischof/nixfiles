{ pkgs, ... }:
let
  ectool = "${pkgs.fw-ectool}/bin/ectool";
  fanctrl = "${pkgs.fw-fanctrl}/bin/fw-fanctrl";

  # While the lid is shut but the machine stays awake: battery LED blue, and the
  # fan on the "deaf" strategy; otherwise LED back to EC control ("auto") and the
  # fan back to the default/discharging strategy. Awake-while-closed means a
  # block sleep inhibitor is held (so logind won't suspend on lid close), which
  # we read from logind's BlockInhibited. The EC rejects the left/right IDs and
  # white with INVALID_PARAM, so we use the battery LED with blue.
  apply = pkgs.writeShellScript "lid-closed-apply" ''
    set -eu

    lid=open
    for f in /proc/acpi/button/lid/*/state; do
      [ -r "$f" ] && read -r _ lid < "$f" || true
    done

    blocked="$(${pkgs.systemd}/bin/busctl --no-pager get-property \
      org.freedesktop.login1 /org/freedesktop/login1 \
      org.freedesktop.login1.Manager BlockInhibited 2>/dev/null || true)"

    awake=0
    case "$blocked" in *sleep*) awake=1 ;; esac

    # fw-fanctrl may be down (restarting during a switch); don't let that stop
    # the LED from being set.
    if [ "$lid" = closed ] && [ "$awake" -eq 1 ]; then
      ${ectool} led battery blue
      ${fanctrl} use deaf || true
    else
      ${ectool} led battery auto
      # Undo only the strategy the branch above sets, so one picked in the
      # bar's battery dropdown survives opening the lid and resuming. "deaf"
      # picked there by hand is indistinguishable, and goes with the lid.
      current="$(${fanctrl} --output-format JSON print current 2>/dev/null \
        | ${pkgs.jq}/bin/jq -r .strategy || true)"
      if [ "$current" = deaf ]; then
        ${fanctrl} reset || true
      fi
    fi
  '';
in
{
  # The FW13 exhausts through the gap under the hinge, between the deck and the
  # open display; a shut lid chokes that path and the deck heats the panel from
  # below. The fan curve only sees the CPU temperature, which runs about as hot
  # either way, so it ramps no earlier with the lid shut. "deaf" (shipped with
  # fw-fanctrl) is 100% from 60°C. Under a full compile every curve sits at
  # 100%; this only helps sustained medium load. Capping power is the lever for
  # peaks, and was declined to keep compile speed.

  # logind suppresses only the suspend on lid close; acpid still gets the raw
  # button/lid events, which is where we re-evaluate.
  services.acpid = {
    enable = true;
    lidEventCommands = "${apply}";
  };

  # Hand the LED back to the EC before sleeping; re-evaluate on resume.
  environment.etc."systemd/system-sleep/lid-closed-led".source =
    pkgs.writeShellScript "lid-closed-led-sleep" ''
      set -eu
      case "$1" in
        pre) ${ectool} led battery auto ;;
        post) ${apply} ;;
      esac
    '';
}
