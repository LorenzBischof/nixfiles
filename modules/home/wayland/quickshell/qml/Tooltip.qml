import QtQuick
import Quickshell

// Shown under a module after the pointer has rested on it for a moment.
PopupWindow {
    id: root

    required property Item target
    property string text: ""
    property bool active: false

    readonly property int horizontalPadding: 10
    readonly property int verticalPadding: 6

    anchor.item: target
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom
    anchor.margins.top: 4

    color: "transparent"
    implicitWidth: label.implicitWidth + root.horizontalPadding * 2
    implicitHeight: label.implicitHeight + root.verticalPadding * 2
    visible: root.active && root.text !== ""

    Rectangle {
        anchors.fill: parent
        color: Config.background
        radius: 5
        border.width: 1
        border.color: Config.accent

        BarText {
            id: label

            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            text: root.text
            color: Config.accentForeground
        }
    }
}
