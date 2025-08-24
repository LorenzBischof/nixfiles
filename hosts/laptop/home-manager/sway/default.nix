{
  config,
  pkgs,
  lib,
  ...
}:

{
  home.packages = with pkgs; [
    wob
    #autotiling-rs
    grim
    sway-contrib.grimshot
    slurp
    wl-clipboard
    wdisplays
    warpd
    wtype
    wf-recorder
  ];

  #  services.kanshi = {
  #    enable = true;
  #    profiles = {
  #      undocked = {
  #        outputs = [
  #          {
  #            criteria = "eDP-1";
  #          }
  #        ];
  #      };
  #      docked = {
  #        outputs = [
  #          {
  #            criteria = "eDP-1";
  #            mode = "1920x1080";
  #            position = "1920,120";
  #          }
  #          {
  #            criteria = "DP-5";
  #            mode = "1920x1200";
  #            position = "0,0";
  #          }
  #        ];
  #      };
  #    };
  #  };

  stylix.targets.swaylock.useWallpaper = false;
  programs = {
    fuzzel = {
      enable = true;
      settings = {
        main = {
          width = 15;
          lines = 9;
          horizontal-pad = 18;
          vertical-pad = 18;
          inner-pad = 24;
          line-height = 25;
        };
        border = {
          width = 5;
          radius = 0;
        };
      };
    };
    swaylock = {
      enable = true;
      settings = {
        color = lib.mkForce "000000";
        hide-keyboard-layout = true;
        show-failed-attempts = true;
        indicator-idle-visible = true;
      };
    };
    i3status-rust = {
      enable = true;
      bars.default = {
        theme = "native";
        icons = "awesome6";
        blocks = [
          {
            block = "custom";
            signal = 4;
            command = ''
              if ! systemctl --user is-active numen > /dev/null; then 
                  echo 
              else 
                if [ -f "$HOME/.local/state/numen/paused" ]; then 
                  echo 
                else 
                  echo 
                fi; 
              fi
            '';
            interval = 5;
          }
          {
            block = "net";
            device = "wlp2s0";
            format = "$ssid";
            format_alt = "$ip $signal_strength $speed_down.eng(prefix:K) $speed_up.eng(prefix:K)";
            interval = 5;
          }
          {
            block = "sound";
            #   on_click = "pavucontrol -t 1";
            headphones_indicator = true;
          }
          {
            block = "sound";
            device_kind = "source";
            #   on_click = "pavucontrol -t 2";
            headphones_indicator = true;
          }
          {
            block = "battery";
            if_command = "test -e /sys/class/power_supply/BAT0";
          }
          {
            block = "time";
            interval = 5;
            format = "$timestamp.datetime(f:'%R')";
          }
        ];
      };
    };
  };

  services.gammastep = {
    enable = true;
    latitude = 46.9;
    longitude = 7.4;
  };
  services.swayidle = {
    enable = true;
    events = [
      {
        event = "before-sleep";
        command = "${pkgs.swaylock}/bin/swaylock -f";
      }
    ];
    timeouts = [
      {
        timeout = 300;
        command = "${pkgs.brillo}/bin/brillo -O && ${pkgs.brillo}/bin/brillo -equ 200000 -S 1";
        resumeCommand = "${pkgs.brillo}/bin/brillo -I -equ 200000";
      }
      {
        timeout = 310;
        command = "${pkgs.swaylock}/bin/swaylock -f";
      }
      {
        timeout = 320;
        command = "${pkgs.sway}/bin/swaymsg 'output * dpms off'";
        resumeCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms on'";
      }
    ];
  };

  wayland.windowManager.sway = {
    enable = true;
    # https://github.com/nix-community/home-manager/issues/5311
    checkConfig = false;
    extraConfigEarly = ''
      set $WOBSOCK $XDG_RUNTIME_DIR/wob.sock
      exec mkfifo $WOBSOCK && tail -f $WOBSOCK | wob
    '';
    config = rec {
      modifier = "Mod4";
      terminal = "foot";
      startup = [
        #{ command = "autotiling-rs"; always = true; }
      ];
      window = {
        border = 5;
        titlebar = false;
      };
      bars = [
        (lib.attrsets.recursiveUpdate config.stylix.targets.sway.exportedBarConfig {
          statusCommand = "i3status-rs ~/.config/i3status-rust/config-default.toml";
          position = "top";
          extraConfig = ''
            separator_symbol ""
          '';
          fonts = {
            names = [ "DejaVu Sans Mono" ];
            size = 12.0;
          };
          colors.statusline = config.lib.stylix.colors.withHashtag.base04;
        })
      ];
      up = "k";
      down = "j";
      right = "l";
      left = "h";
      keybindings =
        let
          mod = config.wayland.windowManager.sway.config.modifier;
        in
        lib.mkOptionDefault {
          # sway-terminal opens foot or executes ctrl+t in Keepass
          "${mod}+t" = "exec sway-terminal";
          "${mod}+b" = ''
            [con_id="__focused__" app_id="org.keepassxc.KeePassXC"] exec wtype -M ctrl b -m ctrl
          '';
          "${mod}+u" = ''
            [con_id="__focused__" app_id="org.keepassxc.KeePassXC"] exec wtype -M ctrl u -m ctrl
          '';
          "${mod}+q" = ''
            [con_id="__focused__" app_id="^(?!foot|org.keepassxc.KeePassXC|Logseq).*$"] kill; [con_id="__focused__" app_id="foot"] exec wtype -M ctrl d -m ctrl; [con_id=__focused__ app_id="org.keepassxc.KeePassXC" tiling] move scratchpad; [con_id=__focused__ app_id="Logseq" tiling] move scratchpad; [con_id=__focused__ floating] floating disable
          '';
          "${mod}+a" = "exec ${pkgs.fuzzel}/bin/fuzzel";
          "${mod}+n" = "exec ${pkgs.swaylock}/bin/swaylock";
          "${mod}+p" = "split h";
          "${mod}+w" = "split v";
          "${mod}+z" = "fullscreen";
          "${mod}+s" = "layout toggle tabbed split";
          # Alternative solution: https://www.reddit.com/r/swaywm/comments/wtdubk/bind_the_same_key_to_start_move_to_scratchpad/
          # Adding the following seems to always start keepassxc: [app_id="^(?!org.keepassxc.KeePassXC).*$"] exec keepassxc
          "${mod}+m" = ''
            [app_id="org.keepassxc.KeePassXC" tiling] focus; [app_id="org.keepassxc.KeePassXC" floating] scratchpad show
          '';
          "${mod}+g" = ''
            [app_id="Logseq" tiling] focus; [app_id="Logseq" floating] scratchpad show
          '';
          "${mod}+x" = "exec warpd --hint";
          "XF86AudioRaiseVolume" =
            "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ && wpctl get-volume @DEFAULT_AUDIO_SINK@ | sed 's/[^0-9]//g' > $WOBSOCK";
          "XF86AudioLowerVolume" =
            "exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && wpctl get-volume @DEFAULT_AUDIO_SINK@ | sed 's/[^0-9]//g' > $WOBSOCK";
          "XF86AudioMute" =
            "exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && (wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -q MUTED && echo 0 > $WOBSOCK) || wpctl get-volume @DEFAULT_AUDIO_SINK@ | sed 's/[^0-9]//g' > $WOBSOCK";

          "XF86MonBrightnessUp" = "exec brillo -equ 200000 -A 10 && brillo -G | cut -d'.' -f1 > $WOBSOCK";
          "XF86MonBrightnessDown" = "exec brillo -equ 200000 -U 10 && brillo -G | cut -d'.' -f1 > $WOBSOCK";
        };
      input = {
        "*" = {
          xkb_layout = "de(adnw),ch(de_nodeadkeys)";
          xkb_options = "grp:alt_shift_toggle";
        };
        "5824:10203:Glove80_Left_Keyboard" = {
          xkb_layout = "ch(de_nodeadkeys)";
        };
        "1133:50184:Logitech_USB_Trackball" = {
          left_handed = "enabled";
          natural_scroll = "enabled";
          scroll_button = "BTN_EXTRA";
          scroll_method = "on_button_down";
        };
        # Alternative to opentabletdriver: https://www.reddit.com/r/swaywm/comments/ppx6xt/configuring_a_wacom_tablet_where_to_start/
      };
      output = {
        "*" = {
          #bg = builtins.toString ./wallpaper_cropped_1.png + " fill";
        };
        "eDP-1" = {
          bg = builtins.toString ./wallpaper_cropped_0.png + " fill";
          position = "1920 120";
        };
        "DP-5" = {
          position = "0 0";
        };
        "HDMI-A-1" = {
          position = "0 0";
        };
        "DP-6" = {
          position = "0 0";
        };
      };
    };
    extraSessionCommands = ''
      export XDG_SESSION_TYPE=wayland
      export XDG_CURRENT_DESKTOP=sway
      export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
      export QT_AUTO_SCREEN_SCALE_FACTOR=0
      export QT_SCALE_FACTOR=1
      export GDK_SCALE=1
      export GDK_DPI_SCALE=1
      export MOZ_ENABLE_WAYLAND=1
      export _JAVA_AWT_WM_NONREPARENTING=1
    '';
    wrapperFeatures = {
      gtk = true;
    };
  };
  home.file = {
    ".config/warpd/config".text = ''
      buttons: p w m
    '';
  };
}
