{
  config,
  pkgs,
  lib,
  ...
}:
let
  sway-terminal = pkgs.writeShellApplication {
    name = "sway-terminal";
    runtimeInputs = [ pkgs.jq ];
    text = builtins.readFile ./sway-terminal.sh;
  };
  export-display-config = pkgs.writeShellApplication {
    name = "export-display-config";
    runtimeInputs = [
      pkgs.jq
      pkgs.sway
    ];
    text = builtins.readFile ./export-display-config.sh;
  };
in
{
  imports = [
    ./foot.nix
    ./quickshell
  ];

  home.packages = with pkgs; [
    #autotiling-rs
    grim
    sway-contrib.grimshot
    slurp
    wl-clipboard
    wdisplays
    warpd
    wtype
    wf-recorder
    libnotify
    sway-terminal
    export-display-config
  ];

  # https://github.com/nix-community/home-manager/pull/7817
  # mkForce overrides stylix, which now sets gtk4.theme explicitly (stylix#2330)
  gtk.gtk4.theme = lib.mkForce null;

  stylix.targets.swaylock.image.enable = false;
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
  };

  services.gammastep = {
    enable = true;
    latitude = 46.9;
    longitude = 7.4;
  };
  services.swayidle = {
    enable = true;
    events.before-sleep = "${pkgs.swaylock}/bin/swaylock -f";
    timeouts = [
      {
        timeout = 300;
        command = "${pkgs.brillo}/bin/brillo -O && ${pkgs.brillo}/bin/brillo -equ 200000 -S 1";
        resumeCommand = "${pkgs.brillo}/bin/brillo -I -equ 200000";
      }
      {
        timeout = 330;
        command = "${pkgs.swaylock}/bin/swaylock -f";
      }
      {
        timeout = 340;
        command = "${pkgs.sway}/bin/swaymsg 'output * dpms off'";
        resumeCommand = "${pkgs.sway}/bin/swaymsg 'output * dpms on'";
      }
      {
        timeout = 350;
        command = "${pkgs.systemd}/bin/systemctl suspend-then-hibernate";
      }
    ];
  };

  wayland.windowManager.sway = {
    enable = true;
    # https://github.com/nix-community/home-manager/issues/5311
    checkConfig = false;
    config = rec {
      modifier = "Mod4";
      terminal = "foot";
      startup =
        lib.optionals config.services.kanshi.enable [
          {
            command = "${pkgs.kanshi}/bin/kanshictl reload";
            always = true;
          }
        ]
        ++ [
          #{ command = "autotiling-rs"; always = true; }
        ];
      window = {
        border = 5;
        titlebar = false;
      };
      bars = [ ];
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
          "ssharp" = "exec voxtype record start";
          "--release ssharp" = "exec voxtype record stop";

          # Tap Right-Ctrl to put the F-row legend up for a few seconds on a
          # blank keyboard; tap again to dismiss it early. Fn would be the
          # obvious key, but Framework's EC swallows it and only ever forwards
          # the already-translated F-row scancode, so no evdev device on the
          # machine advertises KEY_FN and nothing in userspace can see it. See
          # quickshell/qml/FnOverlayState.qml.
          "--no-repeat Control_R" = "exec fn-overlay toggle";
          # `osd` draws the level in the bar's own shell; see
          # quickshell/qml/OsdState.qml. It reads the value back itself, so the
          # bindings only have to say which of the two changed.
          "XF86AudioRaiseVolume" = "exec wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+ && osd volume";
          "XF86AudioLowerVolume" = "exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && osd volume";
          "XF86AudioMute" = "exec wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && osd volume";

          # -q steps a constant ratio, max^(step/100), so 3 is 1.39x here and
          # eight presses cover the range above the min cap at the bottom of
          # this file.
          #
          # The step ratio has to exceed the widest band in the panel's output,
          # or two presses land in one band and one of them does nothing. The
          # widest measured is 1.34 (raw 5269-7067): 3 clears it, 2 (1.25x) does
          # not.
          #
          # The steps are not even in light: measured 2.11x on the first press
          # off full, down to 1.21x by the sixth. A table of raw values solved
          # off the curve holds 1.26-1.36x over thirteen presses instead of
          # eight; tried on the panel, not kept.
          "XF86MonBrightnessUp" = "exec brillo -equ 200000 -A 3 && osd brightness";
          "XF86MonBrightnessDown" = "exec brillo -equ 200000 -U 3 && osd brightness";
        };
      input = {
        "*" = {
          xkb_layout = "de(adnw),ch(de_nodeadkeys)";
          xkb_options = "grp:alt_shift_toggle";
          natural_scroll = "enabled";
        };
        "type:touchpad" = {
          tap = "enabled";
          tap_button_map = "lrm";
          dwt = "enabled";
        };
        "5824:10203:Glove80_Left_Keyboard" = {
          xkb_layout = "ch(de_nodeadkeys)";
        };
        "7504:24926:ZMK_Project_Piantor_Keyboard" = {
          xkb_layout = "ch(de_nodeadkeys)";
        };
        "1133:50184:Logitech_USB_Trackball" = {
          left_handed = "enabled";
          scroll_button = "BTN_EXTRA";
          scroll_method = "on_button_down";
        };
        # Alternative to opentabletdriver: https://www.reddit.com/r/swaywm/comments/ppx6xt/configuring_a_wacom_tablet_where_to_start/
      };
      output = {
        "*" = {
          # Not cosmetic: on the laptop panel this is worth 0.6 W on battery
          # (5.0 W with it on, 5.6 W off, idle desktop). With VRR the panel
          # sits at its minimum refresh whenever the screen is static, which
          # is also why capping eDP-1 to 60 Hz on battery saves nothing.
          adaptive_sync = "on";
        };
        "eDP-1" = {
          bg = "${./wallpaper_cropped_0.png} fill";
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

  # Dimmest raw value this panel responds to; brillo clamps every write to it,
  # so it bounds the keys, the swayidle dim above, and the `osd` readout.
  #
  # Measured with amdgpu's `actual_brightness`, which is a hardware readback
  # rather than an echo of `brightness`, with ABM off:
  #
  #   raw 65535 -> 62579   raw 13475 -> 4369   raw 9100 -> 3598
  #   raw 42738 -> 23901   raw 11853 -> 4112   raw 7050 -> 1799
  #   raw 25587 ->  9766   raw  9990 -> 3855   raw 5250 ->    0
  #
  # sysfs reports `scale = non-linear` for this controller; d(ln light)/d(ln
  # raw) is 2.3 at the top and 0.45 at the bottom. Light is quantised in steps
  # of 257, and below 257*14 the only levels are 257*7 and 0 -- stepping every
  # raw value across both transitions found nothing between them, so the last
  # two presses are a 2x drop and then this cap. panel_power_savings=2 scales
  # the whole curve by a constant (1.93 everywhere, 1.89 at full), so the cap
  # holds on battery and on AC.
  #
  # brillo writes this file itself on `brillo -rc -S`; declared here instead. It
  # is only ever read, so a store symlink is fine. The controller name is part
  # of the filename -- if it stops matching `brillo -L` the file is not found
  # and the floor goes back to raw 1.
  xdg.cacheFile."brillo/backlight.amdgpu_bl1.mincap".text = "5250";
}
