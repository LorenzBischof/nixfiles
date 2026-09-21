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
      pkgs.jq
      pkgs.systemd
    ];
    text = ''
      ours=false
      if systemctl --user --quiet is-active ${lib.escapeShellArg idleInhibitUnit}; then
        ours=true
      fi

      # --what filters --list and --json prints the fields rather than a
      # column layout, both since systemd 260. The table this used to scan
      # with awk put WHY between a WHAT it had to find and a MODE it had to
      # count back from, which is exactly the parse a machine-readable form
      # removes.
      # `jq -s` because a --list that matches nothing prints nothing at all
      # rather than an empty array, and a bare filter over no input emits no
      # object and still exits 0 -- so the module would be handed an empty
      # string to parse exactly when it should be told that nothing inhibits
      # idle. Slurping turns both cases into an array to index.
      #
      # stderr is left alone: a broken query should say so in the journal
      # rather than be indistinguishable from that same answer.
      systemd-inhibit --list --no-pager --what=idle --json=short \
        | jq -sc --argjson ours "$ours" '{reasons: (.[0] // [] | map(.why)), ours: $ours}' \
        || echo "{\"reasons\": [], \"ours\": $ours}"
    '';
  };

  # What the bar watches instead of polling: logind publishes BlockInhibited
  # and NCurrentInhibitors on its manager, and emits a PropertiesChanged
  # carrying both on every inhibitor taken or dropped. The count is the
  # load-bearing half -- a second app taking idle while one already holds it
  # leaves the union at "idle" and would otherwise be silent.
  #
  # `gdbus monitor` rather than `dbus-monitor` or `busctl monitor`: those two
  # ask for org.freedesktop.DBus.Monitoring, which the system bus policy grants
  # to root alone. Passing --dest makes gdbus a plain signal subscriber, which
  # any user may be.
  idleInhibitWatch = pkgs.writeShellApplication {
    name = "idle-inhibit-watch";
    runtimeInputs = [ pkgs.glib ];
    text = ''
      exec gdbus monitor --system \
        --dest org.freedesktop.login1 \
        --object-path /org/freedesktop/login1
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

  # Three upstream fixes for bugs this bar hits, none of them in a release:
  # 0.3.1 (2026-08-21, current nixpkgs-unstable) is still the newest tag and all
  # three landed on master after it. Drop the lot, and this override with them,
  # once a release carries them.
  #
  # nm-service-watcher: NetworkManager restarting under a running quickshell
  # tears its devices down and nothing ever re-registers them, so the bar
  # latches to the red disconnected icon until quickshell itself is restarted.
  # Reproducible with a plain `systemctl restart NetworkManager`, which is
  # exactly what `just switch` does.
  # https://git.outfoxxed.me/quickshell/quickshell/commit/0f9939ca4fac3a1db3653c51a3c23ca9812e2946
  #
  # nm-omitted-mode: joining a network from the wifi dropdown left it spinning
  # forever. Connecting with a password calls AddAndActivateConnection with only
  # the psk and lets NetworkManager complete the rest from the access point; the
  # profile it writes leaves `802-11-wireless.mode` at its default, so NM omits
  # it from GetSettings. quickshell matched that field against "infrastructure"
  # exactly and dropped every profile without it, so the new connection was
  # never attached to the network in the list: `known` stayed false, its state
  # stayed Deactivated, and the row never learned it had connected -- even
  # though NetworkManager had. nmtui writes mode explicitly, which is why it
  # looked like only the bar was broken.
  # https://git.outfoxxed.me/quickshell/quickshell/commit/052059fb7c
  #
  # scriptmodel-native-types: ScriptModel defaults to comparing entries by
  # structure, and 0.3.1 is the one release where that walks a native QObject's
  # properties as if it were a plain javascript object -- so two distinct
  # objects can compare equal, and the model keeps the entry it already had.
  # Every ScriptModel here holds native objects (wifi networks, bluetooth
  # devices, pipewire nodes, workspaces), which is exactly the case this
  # excludes from the structural walk. It also stops each list from deep
  # comparing every property of every row on every update.
  # https://git.outfoxxed.me/quickshell/quickshell/commit/c6a516096d
  quickshell = pkgs.quickshell.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ./nm-service-watcher.patch
      ./nm-omitted-mode.patch
      ./scriptmodel-native-types.patch
    ];
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

  # The other half of what a media key does, run once the volume or brightness
  # itself has been set: sway execs this and it pokes the running shell into
  # putting the new level on screen. Replaces wob, which the keys used to pipe a
  # bare percentage to over a fifo.
  #
  # Volume needs no value -- the shell reads it back off Pipewire, mute flag and
  # all. Brightness has no such service, so it is read here. The binding only
  # gets this far once brillo's fade has finished, so the read reports the level
  # being settled on rather than a frame of the ramp.
  osd = pkgs.writeShellApplication {
    name = "osd";
    runtimeInputs = [
      quickshell
      pkgs.brillo
      pkgs.gawk
    ];
    text = ''
      case "''${1-}" in
      volume)
        exec qs -c bar ipc call osd volume
        ;;
      brightness)
        # -q is the scale the keys step, but it is anchored at raw 1, so it
        # bottoms out at the min cap's share of it rather than at 0 -- 77% with
        # the cap in ../default.nix. -qc reports the cap on that same scale, so
        # rescaling between the two costs plain arithmetic rather than logs of
        # raw values, and puts 0% on the cap. With no cap brillo reports it as
        # raw 1, which is 0 on this scale, and the rescale does nothing.
        #
        # Through variables rather than straight into the arguments: errexit
        # does not look at a command substitution used as an argument, so a
        # brillo that cannot reach the backlight would otherwise put an empty
        # level on screen instead of nothing at all.
        level="$(brillo -qG)"
        floor="$(brillo -qcG)"
        level="$(awk -v level="$level" -v floor="$floor" 'BEGIN {
          if (floor >= 100) { print 100; exit }
          pct = (level - floor) / (100 - floor) * 100
          if (pct < 0) pct = 0
          if (pct > 100) pct = 100
          printf "%.2f\n", pct
        }')"
        exec qs -c bar ipc call osd brightness "$level"
        ;;
      *)
        echo "usage: osd volume|brightness" >&2
        exit 2
        ;;
      esac
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

        // The same three-step shape as the volume ramp, drawn with the glyphs
        // the Fn legend already prints on the two brightness keys.
        readonly property var brightnessIcons: ["󰃞", "󰃟", "󰃠"]

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

        // Brightness has no bar module of its own, only the readout the
        // brightness keys put up, but it picks its icon the same way the volume
        // ramp does so the two readouts are built alike.
        function brightnessIcon(level: real): string {
            const icons = root.brightnessIcons;
            return icons[Math.max(0, Math.min(icons.length - 1, Math.floor(level * icons.length)))];
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

        // Shared by the bar module and the battery dropdown so a level always
        // draws the same icon in both places.
        function batteryIcon(percentage: int, charging: bool, full: bool): string {
            if (full)
                return "󱈑";
            if (charging)
                return "󰂄";
            const icons = root.batteryIcons;
            return icons[Math.min(icons.length - 1, Math.floor(percentage / 10))];
        }

        // A time to full or empty, spelled the same way in the battery tooltip
        // and its dropdown. An hour of zero is dropped rather than printed:
        // under the hour the minutes are the whole of the answer.
        function durationText(seconds: real): string {
            const hours = Math.floor(seconds / 3600);
            const minutes = Math.floor(seconds % 3600 / 60);
            return hours > 0 ? `''${hours} h ''${minutes} min` : `''${minutes} min`;
        }

        // Device-type glyphs for the bluetooth menu, keyed by the freedesktop
        // icon name BlueZ reports. The list is deliberately short: anything
        // unnamed -- common before a device is paired -- and anything rarer
        // than these falls back to the plain bluetooth mark.
        readonly property var bluetoothIcons: ({
            "audio-card": "󰓃",
            "audio-headphones": "󰋋",
            "audio-headset": "󰋎",
            "computer": "󰌢",
            "input-gaming": "󰊖",
            "input-keyboard": "󰌌",
            "input-mouse": "󰍽",
            "multimedia-player": "󰓃",
            "phone": "󰄜",
            "printer": "󰐪",
            "video-display": "󰍹"
        })

        function bluetoothIcon(icon: string): string {
            return root.bluetoothIcons[icon] ?? "󰂯";
        }

        // Toasts are wider than a dropdown: a notification carries a sentence
        // rather than a device name. A body longer than the line cap is elided
        // -- nothing keeps the rest, so a sender with more to say than this
        // wanted a window.
        readonly property int notificationWidth: Math.ceil(metrics.averageCharacterWidth) * 42
        readonly property int notificationBodyLines: 8

        // Seconds a toast stays up when the sender names no timeout of its own.
        readonly property int notificationTimeout: 8

        // A sender's icon is drawn at one line of text, in the same column the
        // urgency mark would otherwise occupy -- an icon here is a mark beside a
        // sentence, not artwork on a card.
        readonly property int notificationIconSize: Math.ceil(metrics.height)

        // Urgency, low to critical, as the mark on a toast and the colour of
        // its rail. Three silhouettes rather than one family: an i, a bell, a
        // triangle, so the level reads before the summary does.
        readonly property var notificationIcons: ["󰋼", "󰂚", "󰀦"]
        readonly property var notificationAccents: [
            root.subtle,
            root.accent,
            root.alert
        ]

        // Clamped rather than indexed directly: urgency arrives over dbus, and
        // the spec's three values are what a well-behaved sender uses, not what
        // the bus guarantees.
        function notificationLevel(urgency: int): int {
            return Math.max(0, Math.min(2, urgency));
        }

        function notificationIcon(urgency: int): string {
            return root.notificationIcons[root.notificationLevel(urgency)];
        }

        function notificationAccent(urgency: int): color {
            return root.notificationAccents[root.notificationLevel(urgency)];
        }

        // The strip of level bars that appears left of the status icons while
        // voxtype is listening, oldest sample at the left. The daemon emits one
        // audio frame every 10 ms, so a bar folding five of them together is a
        // 50 ms column and the strip holds the last one and a quarter seconds.
        //
        // One line of the bar's own text height, and faded down: it is
        // confirmation that the microphone is live, caught out of the corner of
        // the eye while reading something else -- the voxtype module's icon is
        // where the state is actually read.
        readonly property int waveformBars: 24
        readonly property int waveformFramesPerBar: 5
        readonly property int waveformBarWidth: 2
        readonly property int waveformBarSpacing: 2
        readonly property real waveformOpacity: 0.55

        // How long one bar stands for, which is also the rate the strip
        // scrolls at -- the frames are 10 ms apart, so this is the cadence
        // silence has to be pushed at afterwards for the tail of a recording
        // to scroll off at the speed it scrolled on.
        readonly property int waveformBarInterval: root.waveformFramesPerBar * 10
        readonly property int waveformWidth: root.waveformBars * (root.waveformBarWidth + root.waveformBarSpacing) - root.waveformBarSpacing
        readonly property int waveformHeight: Math.ceil(metrics.height)

        readonly property string voxtype: ${builtins.toJSON (lib.getExe config.programs.voxtype.package)}
        readonly property string voxtypeAudioBridge: ${
          builtins.toJSON (lib.getExe' config.programs.voxtype.package "voxtype-audio-bridge")
        }
        readonly property string pavucontrol: ${builtins.toJSON (lib.getExe pkgs.pavucontrol)}
        readonly property string idleInhibitStatus: ${builtins.toJSON (lib.getExe idleInhibitStatus)}
        readonly property string idleInhibitToggle: ${builtins.toJSON (lib.getExe idleInhibitToggle)}
        readonly property string idleInhibitWatch: ${builtins.toJSON (lib.getExe idleInhibitWatch)}

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

  home.packages = [
    fnOverlay
    osd
  ];
}
