{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.programs.foot;

  # foot asks sway for urgency on BEL only while unfocused (bell.urgent), and
  # sway drops it again once the window is focused. Following sway's urgent
  # events therefore gives focus-aware notifications with the window title, and
  # a point to clear them, which foot's own bell.command (no templates, no
  # focus-in hook) cannot.
  footUrgentNtfy = pkgs.writeShellApplication {
    name = "foot-urgent-ntfy";
    runtimeInputs = with pkgs; [
      sway
      jq
      curl
    ];
    text = ''
      host="$(< /proc/sys/kernel/hostname)"
      declare -A published=()

      swaymsg -t subscribe -m '["window"]' |
        jq --unbuffered -r '
          select(.container.app_id == "foot" and (.change == "urgent" or .change == "close"))
          | [.container.id, (.change == "urgent" and .container.urgent), .container.name]
          | @tsv' |
        while IFS=$'\t' read -r id urgent title; do
          url="https://ntfy.sh/${cfg.urgentNtfyTopic}/$host-foot-$id"
          if [ "$urgent" = true ]; then
            curl -fsS --max-time 10 -H "Title: Waiting on $host" -d "$title" "$url" >/dev/null || true
            published[$id]=1
          elif [ -n "''${published[$id]:-}" ]; then
            curl -fsS --max-time 10 -X PUT "$url/clear" >/dev/null || true
            unset "published[$id]"
          fi
        done
    '';
  };
in
{
  options.my.programs.foot.urgentNtfyTopic = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    description = "ntfy.sh topic that receives the title of foot windows ringing the bell while unfocused.";
  };

  config = {
    programs.foot = {
      enable = true;
      settings = {
        main = {
          term = "xterm-256color";
          font = "monospace:size=18";
          initial-color-theme = "dark";
        };
        bell.urgent = "yes";
        colors-dark = with config.my.theme.palette; {
          foreground = base05;
          background = base00;
          regular0 = base00;
          regular1 = base08;
          regular2 = base0B;
          regular3 = base0A;
          regular4 = base0D;
          regular5 = base0E;
          regular6 = base0C;
          regular7 = base05;
          bright0 = base03;
          bright1 = base08;
          bright2 = base0B;
          bright3 = base0A;
          bright4 = base0D;
          bright5 = base0E;
          bright6 = base0C;
          bright7 = base07;
          "16" = base09;
          "17" = base0F;
          "18" = base01;
          "19" = base02;
          "20" = base04;
          "21" = base06;
        };
      };
    };

    systemd.user.services.foot-urgent-ntfy = lib.mkIf (cfg.urgentNtfyTopic != null) {
      Unit = {
        Description = "Push urgent foot windows to ntfy";
        PartOf = [ "sway-session.target" ];
        After = [ "sway-session.target" ];
      };
      Service = {
        ExecStart = lib.getExe footUrgentNtfy;
        # The subscription ends cleanly when sway reloads or restarts.
        Restart = "always";
        RestartSec = 5;
      };
      Install.WantedBy = [ "sway-session.target" ];
    };
  };
}
