import QtQuick
import Quickshell.Io

// The helper reports which idle inhibitors are active and whether the one this
// module manages is among them. Clicking toggles that one.
BarModule {
    id: root

    property var status: null

    readonly property var reasons: root.status?.reasons ?? []
    readonly property bool ours: root.status?.ours ?? false

    buttons: Qt.LeftButton

    text: root.reasons.length > 0 ? "󰅶" : "󰾪"
    textColor: root.ours ? Config.ok : Config.foreground
    tooltipText: root.reasons.length > 0 ? root.reasons.join("\n") : "No idle inhibitors"

    onClicked: toggle.running = true

    Process {
        id: query

        running: true
        command: [Config.idleInhibitStatus]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.status = JSON.parse(this.text);
                } catch (e) {
                    root.status = null;
                }
            }
        }
    }

    Process {
        id: toggle

        command: [Config.idleInhibitToggle]

        // systemd-run returns before the transient unit is up.
        onExited: settle.restart()
    }

    Timer {
        id: settle

        interval: 300
        onTriggered: query.running = true
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        onTriggered: query.running = true
    }
}
