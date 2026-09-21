pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.I3

// One button per sway workspace on this screen, in numeric order. Clicking
// switches to a workspace. There is deliberately nothing bound to the wheel:
// a touchpad reports one gesture as a stream of events, so scrolling here
// walked several workspaces away from the one being aimed at.
Row {
    id: root

    required property string screenName

    readonly property var workspaces: I3.workspaces.values.filter(ws => ws.monitor && ws.monitor.name === root.screenName).sort((a, b) => a.num - b.num)

    Repeater {
        // The filter and sort build a fresh array on every sway event, and a
        // Repeater handed one rebuilds every delegate. ScriptModel diffs it
        // against the last instead, so a workspace button survives anything
        // that did not happen to it -- as the wifi and bluetooth lists do.
        model: ScriptModel {
            values: root.workspaces
        }

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

                onClicked: {
                    Dropdowns.close();
                    button.modelData.activate();
                }
            }
        }
    }
}
