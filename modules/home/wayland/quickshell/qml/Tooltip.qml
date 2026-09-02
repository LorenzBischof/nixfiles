import QtQuick
import Quickshell

// Shown under a module after the pointer has rested on it for a moment.
PopupWindow {
    id: root

    required property Item target
    property string text: ""
    property bool active: false

    anchor.item: root.target
    anchor.edges: Edges.Bottom
    anchor.gravity: Edges.Bottom

    color: "transparent"
    implicitWidth: label.implicitWidth + Config.tooltipPadding * 2 + Config.popupOutline * 2
    implicitHeight: label.implicitHeight + Config.verticalPadding * 2 + Config.popupOutline * 2
    visible: root.active && root.text !== ""

    PopupSurface {
        anchors.fill: parent

        BarText {
            id: label

            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            text: root.text
            color: Config.popupText
        }
    }
}
