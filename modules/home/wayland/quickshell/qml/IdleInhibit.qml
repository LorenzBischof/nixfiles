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

    // logind announces every inhibitor taken or dropped, so this replaces the
    // poll that used to run the query every five seconds for the life of the
    // bar. Any line is a reason to re-read: the signals that are not about
    // inhibitors at all -- a session opening, a suspend about to happen -- are
    // rare enough that filtering them would cost more than the query does.
    Process {
        id: watch

        running: true
        command: [Config.idleInhibitWatch]

        stdout: SplitParser {
            onRead: query.running = true
        }

        // The subscription is the only thing keeping this module current, so
        // losing it would latch the icon silently. Restarting also re-queries:
        // gdbus greets a fresh subscription with a line of its own, which is
        // the read above.
        onExited: watchRestart.restart()
    }

    Timer {
        id: watchRestart

        interval: 5000
        onTriggered: watch.running = true
    }
}
