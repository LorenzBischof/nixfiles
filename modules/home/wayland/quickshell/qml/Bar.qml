import QtQuick
import Quickshell

// One bar per screen: workspaces on the left, the clock centred, status icons
// on the right.
PanelWindow {
    id: bar

    required property var modelData

    screen: modelData
    color: Config.background
    implicitHeight: Config.barHeight

    anchors {
        top: true
        left: true
        right: true
    }

    Item {
        anchors.fill: parent
        anchors.rightMargin: Config.edgeMargin

        Workspaces {
            anchors.left: parent.left
            screenName: bar.screen.name
        }

        Clock {
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Row {
            anchors.right: parent.right
            spacing: Config.moduleSpacing

            IdleInhibit {}

            BluetoothStatus {}

            NetworkStatus {}

            Voxtype {}

            Volume {}

            Battery {}
        }
    }
}
