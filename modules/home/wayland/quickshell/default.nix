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

        readonly property color background: ${builtins.toJSON colors.base00}
        readonly property color foreground: ${builtins.toJSON colors.base04}
        readonly property color accent: ${builtins.toJSON colors.base0D}
        readonly property color accentForeground: ${builtins.toJSON colors.base05}
        readonly property color alert: ${builtins.toJSON colors.base08}
        readonly property color ok: ${builtins.toJSON colors.base0B}

        readonly property var batteryIcons: ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
        readonly property var volumeIcons: ["󰕿", "󰖀", "󰕾"]

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
  home.packages = [ pkgs.quickshell ];

  xdg.configFile."quickshell/bar".source = shellConfig;

  systemd.user.services.quickshell = {
    Unit = {
      Description = "Quickshell status bar";
      Documentation = "https://quickshell.org";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      Requisite = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.quickshell} --config bar";
      Restart = "on-failure";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
