{ pkgs, ... }:
let
  ectool = "${pkgs.fw-ectool}/bin/ectool";

  # Battery LED blue while the lid is shut but the machine stays awake, else
  # back to EC control ("auto"). Awake-while-closed means a block sleep
  # inhibitor is held (so logind won't suspend on lid close), which we read from
  # logind's BlockInhibited. The EC rejects the left/right IDs and white with
  # INVALID_PARAM, so we use the battery LED with blue.
  apply = pkgs.writeShellScript "lid-closed-led-apply" ''
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

    if [ "$lid" = closed ] && [ "$awake" -eq 1 ]; then
      ${ectool} led battery blue
    else
      ${ectool} led battery auto
    fi
  '';
in
{
  # logind suppresses only the suspend on lid close; acpid still gets the raw
  # button/lid events, which is where we re-evaluate the LED.
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
