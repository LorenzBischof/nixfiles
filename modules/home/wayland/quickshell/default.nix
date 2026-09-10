{
  config,
  lib,
  pkgs,
  ...
}:
let
  colors = config.lib.stylix.colors.withHashtag;

  idleInhibitUnit = "idle-inhibit.service";

  # Reports the reasons of every active idle inhibitor, and whether the one
  # `idleInhibitToggle` manages is among them.
  idleInhibitStatus = pkgs.writeShellApplication {
    name = "idle-inhibit-status";
    runtimeInputs = [
      pkgs.gawk
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      # TODO: systemd 260+ supports --what=idle and --json=short for --list, simplifying this to:
      # reasons="$(systemd-inhibit --list --no-legend --no-pager --what=idle --json=short \
      #   | jq -r '.[] | .why')"
      inhibitors="$(systemd-inhibit --list --no-legend --no-pager 2>/dev/null || true)"

      # Extract the WHY field of each idle inhibitor line. MODE is always the
      # last field (block/delay), WHAT is found by scanning for "idle", and WHY
      # is everything in between.
      reasons="$(printf '%s\n' "$inhibitors" | awk '{
        for (i=1; i<=NF; i++) {
          if ($i ~ /(^|:)idle(:|$)/) {
            why = ""
            for (j=i+1; j<NF; j++) why = (why == "") ? $j : (why " " $j)
            print why
            break
          }
        }
      }')"

      ours=false
      if systemctl --user --quiet is-active ${lib.escapeShellArg idleInhibitUnit}; then
        ours=true
      fi

      printf '%s\n' "$reasons" | jq -Rsc --argjson ours "$ours" \
        '{reasons: (split("\n") | map(select(length > 0))), ours: $ours}'
    '';
  };

  idleInhibitToggle = pkgs.writeShellApplication {
    name = "idle-inhibit-toggle";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if systemctl --user --quiet is-active ${lib.escapeShellArg idleInhibitUnit}; then
        systemctl --user stop ${lib.escapeShellArg idleInhibitUnit}
      else
        systemd-run --user \
          --unit=${lib.escapeShellArg (lib.removeSuffix ".service" idleInhibitUnit)} \
          --description="Manual idle inhibitor" \
          --collect \
          ${pkgs.systemd}/bin/systemd-inhibit \
            --what=handle-lid-switch:idle:sleep \
            --mode=block \
            --why="Manual idle inhibitor" \
            ${pkgs.coreutils}/bin/sleep infinity
      fi
    '';
  };

  # quickshell probes for NetworkManager's bus name exactly once, when its
  # Networking singleton is first touched, and never retries: qml.cpp deletes
  # the backend outright unless `proxy->isValid()`. If the name is not there
  # yet it logs "Could not find an available backend" and leaves the device
  # list empty for the life of the process, so NetworkStatus is stuck on the
  # red disconnected icon. Losing that race is easy during a `just switch`,
  # which restarts NetworkManager and the user units without ordering between
  # them. A user unit cannot order itself after a system unit, so wait for the
  # bus name instead.
  #
  # This only covers quickshell starting *before* NetworkManager. NetworkManager
  # restarting afterwards is a separate bug, fixed by the patch below.
  waitForNetworkManager = pkgs.writeShellApplication {
    name = "wait-for-networkmanager";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      # Ask the bus daemon, not NetworkManager: this stays cheap and cannot be
      # tripped up by NetworkManager's own dbus policy or by it still starting.
      for _ in $(seq 300); do
        if busctl --system call org.freedesktop.DBus /org/freedesktop/DBus \
          org.freedesktop.DBus NameHasOwner s org.freedesktop.NetworkManager \
          2>/dev/null | grep -q 'b true'; then
          exit 0
        fi
        sleep 0.1
      done
      echo "NetworkManager did not appear on the system bus within 30s; the bar's network module will be dead" >&2
    '';
  };

  # NetworkManager restarting under a running quickshell tears its devices down
  # and nothing ever re-registers them, so the bar latches to the red
  # disconnected icon until quickshell itself is restarted. Reproducible with a
  # plain `systemctl restart NetworkManager`, which is exactly what `just
  # switch` does. Upstream fixed it by watching the bus name, but the commit is
  # in no release yet: neither 0.3.0 nor 0.3.1 (current nixpkgs-unstable)
  # contains it. Drop this once a release does.
  # https://git.outfoxxed.me/quickshell/quickshell/commit/0f9939ca4fac3a1db3653c51a3c23ca9812e2946
  quickshell = pkgs.quickshell.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./nm-service-watcher.patch ];
  });

  # sway's only handle on the Fn key overlay. A keybinding can only exec a
  # process, so the Right-Ctrl binding goes through quickshell's IPC socket to
  # reach the already-running shell. The config name has to match the one the
  # unit launches, hence -c bar.
  fnOverlay = pkgs.writeShellApplication {
    name = "fn-overlay";
    runtimeInputs = [ quickshell ];
    text = ''
      # The IPC functions are open/close rather than show/hide: `qs ipc call`
      # takes the function name as a positional, and a positional matching a
      # sibling subcommand -- show, call, wait, listen, prop -- is parsed as
      # that subcommand instead, so `ipc call fnOverlay show` prints the
      # target's function list and exits 0 without calling anything. The
      # readable verbs stay on this side of the translation.
      case "''${1-}" in
      show) fn=open ;;
      hide) fn=close ;;
      toggle) fn=toggle ;;
      *)
        echo "usage: fn-overlay show|hide|toggle" >&2
        exit 2
        ;;
      esac

      exec qs -c bar ipc call fnOverlay "$fn"
    '';
  };

  # Everything the QML needs from Nix: the stylix theme, and absolute paths to
  # the helpers the bar shells out to.
  configQml = pkgs.writeText "Config.qml" ''
    pragma Singleton

    import QtQuick
    import Quickshell

    Singleton {
        id: root

        readonly property string fontFamily: ${builtins.toJSON config.stylix.fonts.monospace.name}
        readonly property int fontPointSize: ${toString config.stylix.fonts.sizes.desktop}

        readonly property int modulePadding: 8
        readonly property int moduleSpacing: 4
        readonly property int verticalPadding: 5
        readonly property int edgeMargin: 10
        readonly property int barHeight: Math.ceil(metrics.height) + root.verticalPadding * 2

        // Panels hung under a bar module. Square, and bordered along the edge
        // that meets the bar at the same 5px sway gives a window, so a module
        // and its panel read as two tiled windows rather than a floating card.
        // The other edges stay a hairline: a 5px ring reads as a slab at this
        // size. Text sits a step brighter than in the bar, since it is read
        // rather than glanced at.
        readonly property int popupOutline: 1
        readonly property int popupBorder: 5
        readonly property int tooltipPadding: 10
        readonly property int menuWidth: Math.ceil(metrics.averageCharacterWidth) * 26
        readonly property int menuPadding: 12
        readonly property int menuSpacing: 6
        readonly property int menuRowHeight: Math.ceil(metrics.height) + 8
        readonly property int menuIconWidth: Math.ceil(metrics.averageCharacterWidth) * 2
        readonly property int menuValueWidth: Math.ceil(metrics.averageCharacterWidth) * 4
        readonly property int menuGrooveHeight: 4
        readonly property int menuHandleWidth: 8
        readonly property int menuHandleHeight: 18

        // The Fn legend is a 1:1 picture of the physical function row: each
        // glyph sits directly above the key it describes. Geometry is therefore
        // in millimetres, and FnOverlay.qml scales it by the panel's own width
        // -- which keeps a key where it is whether kanshi has the display at
        // scale 2 (docked) or sway's default 1 (undocked). The built-in display
        // is 13.5" at 3:2, so 285.3 mm across.
        //
        // Framework publishes no key dimensions, and no photo of theirs is
        // square-on enough to measure off, so the four below are estimates.
        // Measure the real keyboard and correct them:
        //
        //   fnRowWidthMm   left edge of Esc to right edge of Delete
        //   fnKeySpanMm    left edge of F1 to right edge of F12
        //   fnKeyWidthMm   one F key's cap, across
        //   fnKeyHeightMm  one F key's cap, top to bottom -- they are flat
        //                  rather than square, and only set the glyph size
        //
        // Everything else follows from those: the F row pitch is
        // (span - width) / 11, and Esc and Delete, which are wider than an F
        // key, centre in whatever is left at each end.
        readonly property real builtinPanelWidthMm: 285.3
        readonly property real fnRowWidthMm: 276.0
        readonly property real fnKeySpanMm: 227.2
        readonly property real fnKeyWidthMm: 15.3
        readonly property real fnKeyHeightMm: 8.0

        // Keycap corner, and the glyphs sitting on them -- also millimetres.
        // Both glyph sizes are set against the 8 mm cap height rather than the
        // width, since that is what they have to fit inside.
        readonly property real fnKeyRadiusMm: 1.0
        readonly property real fnIconMm: 5.5
        readonly property real fnCapTextMm: 3.2
        readonly property real fnBottomMarginMm: 4.0

        readonly property color background: ${builtins.toJSON colors.base00}
        readonly property color surface: ${builtins.toJSON colors.base01}
        readonly property color overlay: ${builtins.toJSON colors.base02}
        readonly property color subtle: ${builtins.toJSON colors.base03}
        // sway's unfocused window border, carried by a panel's top edge except
        // under the module it belongs to, which is marked in the accent.
        readonly property color unfocused: ${builtins.toJSON colors.base03}
        readonly property color foreground: ${builtins.toJSON colors.base04}
        readonly property color accent: ${builtins.toJSON colors.base0D}
        readonly property color accentForeground: ${builtins.toJSON colors.base05}
        readonly property color alert: ${builtins.toJSON colors.base08}
        readonly property color ok: ${builtins.toJSON colors.base0B}

        // Popup text, brighter than the bar so a panel stays readable at rest.
        // One step up the ramp from the bar's own three tones, so even the dim
        // role -- icons, headings, slider values -- clears the bar's foreground.
        readonly property color popupText: ${builtins.toJSON colors.base06}
        readonly property color popupTextDim: ${builtins.toJSON colors.base05}
        readonly property color popupTextStrong: ${builtins.toJSON colors.base07}

        // Signal strength, as an empty ring plus four filled steps. The locked
        // ramp is the same glyph family with a padlock, so a secured network
        // reads as secured without spending a second column on it.
        readonly property var wifiIcons: ["󰤯", "󰤟", "󰤢", "󰤥", "󰤨"]
        readonly property var wifiLockedIcons: ["󰤬", "󰤡", "󰤤", "󰤧", "󰤪"]

        readonly property var batteryIcons: ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
        readonly property var volumeIcons: ["󰕿", "󰖀", "󰕾"]

        // Shared by the bar module and the volume dropdown so a level always
        // draws the same icon in both places.
        function volumeIcon(volume: real, muted: bool): string {
            if (muted)
                return "󰝟";
            if (volume <= 0)
                return "󰝞";
            const icons = root.volumeIcons;
            return icons[Math.min(icons.length - 1, Math.floor(volume * icons.length))];
        }

        // Signal strength as a 0-4 bar count. The wifi menu orders rows on this
        // rather than the raw strength, so a network only changes place when its
        // icon changes too -- otherwise rows shuffle under the pointer as the
        // strength jitters between scans.
        function wifiBars(strength: real): int {
            return Math.max(0, Math.min(4, Math.ceil(strength * 4)));
        }

        // Shared by the bar module and the wifi dropdown so a level always draws
        // the same icon in both places.
        function wifiIcon(strength: real, locked: bool): string {
            return (locked ? root.wifiLockedIcons : root.wifiIcons)[root.wifiBars(strength)];
        }

        readonly property string voxtype: ${builtins.toJSON (lib.getExe pkgs.voxtype-vulkan)}
        readonly property string pavucontrol: ${builtins.toJSON (lib.getExe pkgs.pavucontrol)}
        readonly property string idleInhibitStatus: ${builtins.toJSON (lib.getExe idleInhibitStatus)}
        readonly property string idleInhibitToggle: ${builtins.toJSON (lib.getExe idleInhibitToggle)}

        FontMetrics {
            id: metrics

            font.family: root.fontFamily
            font.pointSize: root.fontPointSize
        }
    }
  '';

  shellConfig = pkgs.runCommand "quickshell-bar" { } ''
    mkdir -p $out
    cp ${./qml}/*.qml $out/
    cp ${configQml} $out/Config.qml
  '';
in
{
  programs.quickshell = {
    enable = true;
    package = quickshell;
    configs.bar = shellConfig;
    activeConfig = "bar";
    systemd.enable = true;
  };

  systemd.user.services.quickshell = {
    Unit = {
      # The generated unit runs the config by name, so a rebuild that only
      # touches QML leaves it byte-identical and nothing restarts the bar: it
      # keeps serving the shell it loaded at startup. quickshell's own live
      # reload does not cover this either, because it watches the config
      # through a symlink to an immutable store path.
      X-Restart-Triggers = [ shellConfig ];

      # Stop the bar with the session rather than leaving it behind, and do not
      # start it at all when there is no session to draw on.
      PartOf = [ "graphical-session.target" ];
      Requisite = [ "graphical-session.target" ];
    };

    Service.ExecStartPre = lib.getExe waitForNetworkManager;
  };

  home.packages = [ fnOverlay ];
}
