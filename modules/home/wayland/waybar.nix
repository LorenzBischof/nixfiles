{
  lib,
  pkgs,
  ...
}:
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
          "inhibitor"
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

        "inhibitor" = {
          what = [ "sleep" ];
          format = "{icon}";
          format-icons = {
            activated = "󰅶";
            deactivated = "󰾪";
          };
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
      #inhibitor {
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

      #inhibitor.activated {
        color: #9ece6a;
      }
    '';
  };
}
