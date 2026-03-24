{
  lib,
  pkgs,
  ...
}:
let
  systemdIdleInhibitUnit = "waybar-idle-inhibit.service";
  systemdIdleInhibitStatus = pkgs.writeShellApplication {
    name = "systemd-idle-inhibit-status";
    runtimeInputs = [
      pkgs.gawk
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      # TODO: systemd 260+ supports --what=idle and --json=short for --list, simplifying this to:
      # idle_whys="$(systemd-inhibit --list --no-legend --no-pager --what=idle --json=short \
      #   | jq -r '.[] | .why')"
      inhibitors="$(systemd-inhibit --list --no-legend --no-pager 2>/dev/null || true)"

      # Extract WHY field from each idle inhibitor line.
      # MODE is always the last field (block/delay); WHAT containing idle is found by scanning;
      # WHY is everything between WHAT and MODE.
      idle_whys="$(printf '%s\n' "$inhibitors" | awk '{
        for (i=1; i<=NF; i++) {
          if ($i ~ /(^|:)idle(:|$)/) {
            why = ""
            for (j=i+1; j<NF; j++) why = (why == "") ? $j : (why " " $j)
            print why
            break
          }
        }
      }')"

      own_inhibitor_active=false
      if systemctl --user --quiet is-active ${lib.escapeShellArg systemdIdleInhibitUnit}; then
        own_inhibitor_active=true
      fi

      if [ -n "$idle_whys" ]; then
        count="$(printf '%s\n' "$idle_whys" | awk 'NF { c++ } END { print c+0 }')"
        class="$([ "$own_inhibitor_active" = true ] && echo activated || echo detected)"
        jq -cn \
          --arg text "󰅶" \
          --arg class "$class" \
          --arg tooltip "$idle_whys" \
          --arg alt "$count" \
          '{text: $text, class: $class, tooltip: $tooltip, alt: $alt}'
      else
        jq -cn \
          --arg text "󰾪" \
          --arg class "deactivated" \
          --arg tooltip "No active idle inhibitors" \
          '{text: $text, class: $class, tooltip: $tooltip}'
      fi
    '';
  };
  idleInhibitSignal = 8;
  systemdIdleInhibitToggle = pkgs.writeShellApplication {
    name = "systemd-idle-inhibit-toggle";
    runtimeInputs = [
      pkgs.procps
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail

      if systemctl --user --quiet is-active ${lib.escapeShellArg systemdIdleInhibitUnit}; then
        systemctl --user stop ${lib.escapeShellArg systemdIdleInhibitUnit}
      else
        systemd-run --user \
          --unit=${lib.escapeShellArg (lib.removeSuffix ".service" systemdIdleInhibitUnit)} \
          --description="Waybar idle inhibitor" \
          --collect \
          ${pkgs.systemd}/bin/systemd-inhibit \
            --what=idle \
            --mode=block \
            --why="Waybar idle inhibitor" \
            ${pkgs.coreutils}/bin/sleep infinity
      fi
      pkill -SIGRTMIN+${toString idleInhibitSignal} waybar || true
    '';
  };
in
{
  programs.waybar = {
    enable = true;
    systemd.enable = true;
    settings = [
      {
        layer = "top";
        position = "top";
        height = 24;
        spacing = 4;
        modules-left = [ "sway/workspaces" ];
        modules-center = [ "clock" ];
        modules-right = [
          "custom/systemd-idle-inhibit"
          "bluetooth"
          "network"
          "custom/voxtype"
          "pulseaudio"
          "battery"
        ];

        "sway/workspaces" = {
        };

        "battery" = {
          format = "{icon}";
          format-icons = [
            "󰂎"
            "󰁺"
            "󰁻"
            "󰁼"
            "󰁽"
            "󰁾"
            "󰁿"
            "󰂀"
            "󰂁"
            "󰂂"
            "󰁹"
          ];
          format-charging = "󰂄";
          format-full = "󱈑";
          states = {
            warning = 20;
            critical = 10;
          };
        };

        "clock" = {
          format = "{:%H:%M}";
          tooltip-format = "{:%Y-%m-%d %A}";
        };

        "network" = {
          format-wifi = "󰖩";
          format-ethernet = "";
          format-disconnected = "󰖪";
          tooltip-format = "{ifname} via {gwaddr}";
        };

        "bluetooth" = {
          format = "󰂯";
          format-disabled = "";
          format-off = "";
          format-connected = "󰂱";
          tooltip-format = "{device_alias}";
        };

        "pulseaudio" = {
          format = "{icon}";
          format-muted = "󰝟";
          reverse-scrolling = true;
          reverse-mouse-scrolling = true;
          format-icons = {
            default = [
              "󰕿"
              "󰖀"
              "󰕾"
            ];
          };
          format-zero = "󰝞";
          states.zero = 0;
          on-click = "pavucontrol";
        };

        "custom/voxtype" =
          let
            voxtypeExe = lib.getExe pkgs.voxtype-vulkan;
          in
          {
            exec = "${voxtypeExe} status --follow --format json --icon-theme material";
            return-type = "json";
            format = "{}";
            tooltip = true;
            on-click = "${voxtypeExe} record toggle";
          };

        "custom/systemd-idle-inhibit" = {
          exec = lib.getExe systemdIdleInhibitStatus;
          interval = 5;
          signal = idleInhibitSignal;
          return-type = "json";
          format = "{}";
          on-click = lib.getExe systemdIdleInhibitToggle;
        };
      }
    ];

    style = ''
      window#waybar,
      #workspaces button {
        color: #A09F93;
      }

      #workspaces button:first-child label {
        padding-left: 5px;
      }

      #waybar > box {
      	margin-right: 10px
      }

      #waybar #workspaces button {
        padding: 0 7px;
        border-radius: 0;
        border-width: 0;
      }

      #workspaces button.focused {
        background: #6699CC;
        color: #d3d0c8;
      }

      #workspaces button.urgent {
        color: #f7768e;
      }

      #battery,
      #network,
      #bluetooth,
      #custom-voxtype,
      #pulseaudio,
      #custom-systemd-idle-inhibit {
        margin: 5px 0;
        padding: 0 8px;
      }


      #battery.charging {
        color: #9ece6a;
      }

      @keyframes blink {
        to {
            opacity: 0;
        }
      }

      #battery.critical:not(.charging) {
        opacity: 1;
        animation-name: blink;
        animation-duration: 1s;
        animation-timing-function: steps(12);
        animation-iteration-count: infinite;
        animation-direction: alternate;
      }

      #network.disconnected {
        color: #f7768e;
      }

      #custom-voxtype.recording {
        color: #f7768e;
      }

      #custom-voxtype.transcribing {
        color: #6699CC;
      }

      #pulseaudio.muted {
        color: #f7768e;
      }

      #custom-systemd-idle-inhibit.activated {
        color: #9ece6a;
      }
    '';
  };
}
