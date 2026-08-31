import QtQuick
import Quickshell.Io

// voxtype streams one JSON status object per line for as long as it runs.
BarModule {
    id: root

    property var status: null

    buttons: Qt.LeftButton

    text: root.status?.text ?? ""
    tooltipText: root.status?.tooltip ?? ""
    visible: root.text !== ""

    textColor: {
        switch (root.status?.class) {
        case "recording":
            return Config.alert;
        case "transcribing":
            return Config.accent;
        default:
            return Config.foreground;
        }
    }

    onClicked: toggle.running = true

    Process {
        id: follow

        running: true
        command: [Config.voxtype, "status", "--follow", "--format", "json", "--icon-theme", "material"]

        stdout: SplitParser {
            onRead: line => {
                try {
                    root.status = JSON.parse(line);
                } catch (e) {
                    root.status = null;
                }
            }
        }

        onExited: restart.restart()
    }

    Process {
        id: toggle

        command: [Config.voxtype, "record", "toggle"]
    }

    Timer {
        id: restart

        interval: 5000
        onTriggered: follow.running = true
    }
}
