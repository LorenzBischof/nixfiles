{
  config,
  pkgs,
  lib,
  ...
}:

{
  #  services.gammastep = {
  #    enable = true;
  #    latitude = 46.9;
  #    longitude = 7.4;
  #  };
  #  services.swayidle = {
  #    enable = true;
  #    events = [
  #      {
  #        event = "before-sleep";
  #        command = "${pkgs.swaylock}/bin/swaylock -f";
  #      }
  #    ];
  #    timeouts = [
  #      {
  #        timeout = 300;
  #        command = "${pkgs.brillo}/bin/brillo -O && ${pkgs.brillo}/bin/brillo -equ 200000 -S 1";
  #        resumeCommand = "${pkgs.brillo}/bin/brillo -I -equ 200000";
  #      }
  #      {
  #        timeout = 310;
  #        command = "${pkgs.swaylock}/bin/swaylock -f";
  #      }
  #      {
  #        timeout = 320;
  #        command = "${pkgs.sway}/bin/swaymsg 'output * dpms off'";
  #        resumeCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms on'";
  #      }
  #    ];
  #  };

  xsession.windowManager.i3 = {
    enable = true;
    config = {
      modifier = "Mod4";
      terminal = "alacritty";
      startup = [
        {
          command = "${pkgs.snixembed}/bin/snixembed";
          notification = false;
        }
        {
          command = "talon";
          notification = false;
        }
        {
          command = "${pkgs.feh}/bin/feh --bg-fill ${../sway/wallpaper_cropped_0.png}";
          notification = false;
        }
      ];
      window = {
        border = 5;
        titlebar = false;
      };
      bars = [
        {
          statusCommand = "i3status-rs ~/.config/i3status-rust/config-default.toml";
          position = "top";
          fonts = {
            names = [ "DejaVu Sans Mono" ];
            size = 12.0;
          };
        }
      ];
      #up = "k";
      #down = "j";
      #right = "l";
      #left = "h";
      keybindings =
        let
          mod = config.xsession.windowManager.i3.config.modifier;
        in
        lib.mkOptionDefault {
          "${mod}+t" = "exec alacritty";
          "${mod}+d" = "kill";
          "${mod}+a" = "exec i3-dmenu-desktop";
          "${mod}+n" = "exec ${pkgs.i3lock}/bin/i3lock -fc 000000";
          "${mod}+p" = "split h";
          "${mod}+w" = "split v";
          "${mod}+z" = "fullscreen";
          "${mod}+s" = "layout toggle tabbed split";
          "XF86AudioRaiseVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+";
          "XF86AudioLowerVolume" = "exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
          "XF86AudioMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";

          "XF86MonBrightnessUp" = "exec brillo -equ 200000 -A 10";
          "XF86MonBrightnessDown" = "exec brillo -equ 200000 -U 10";
        };
    };
  };
}
