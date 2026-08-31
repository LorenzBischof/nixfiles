import QtQuick
import Quickshell
import Quickshell.I3

// One button per sway workspace on this screen, in numeric order. Clicking
// switches to a workspace; scrolling steps through them.
Row {
    id: root

    required property string screenName

    readonly property var workspaces: I3.workspaces.values.filter(ws => ws.monitor && ws.monitor.name === root.screenName).sort((a, b) => a.num - b.num)

    function step(offset: int): void {
        const current = root.workspaces.findIndex(ws => ws.focused);
        if (current === -1)
            return;
        const next = root.workspaces[current + offset];
        if (next)
            next.activate();
    }

    Repeater {
        model: root.workspaces

        Rectangle {
            id: button

            required property var modelData

            color: modelData.focused ? Config.accent : "transparent"
            implicitWidth: Math.round(metrics.advanceWidth) + Config.modulePadding * 2
            implicitHeight: Config.barHeight

            TextMetrics {
                id: metrics

                font: label.font
                text: button.modelData.name
            }

            BarText {
                id: label

                anchors.centerIn: parent
                text: button.modelData.name
                color: button.modelData.focused ? Config.accentForeground : button.modelData.urgent ? Config.alert : Config.foreground
            }

            MouseArea {
                anchors.fill: parent

                onClicked: button.modelData.activate()
                onWheel: wheel => root.step(wheel.angleDelta.y > 0 ? -1 : 1)
            }
        }
    }
}
