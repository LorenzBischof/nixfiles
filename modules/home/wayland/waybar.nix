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
          "idle_inhibitor"
          "bluetooth"
          "network"
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

        "idle_inhibitor" = {
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
      #pulseaudio,
      #idle_inhibitor {
        margin: 5px 0;
        padding: 0 8px;
      }


      #battery.charging {
        color: #9ece6a;
      }

      #battery.critical:not(.charging) {
        color: #f7768e;
      }

      #network.disconnected {
        color: #f7768e;
      }

      #pulseaudio.muted {
        color: #f7768e;
      }

      #idle_inhibitor.activated {
        color: #9ece6a;
      }
    '';
  };
}
