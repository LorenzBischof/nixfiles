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

    // An open panel no longer catches clicks on the bar, so the bar's own
    // background has to dismiss it. Declared first, and so below the modules
    // and workspaces: their handlers still get their clicks first.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onClicked: Dropdowns.close()
    }

    // One panel window for the whole bar rather than one per module: see
    // Dropdown.qml.
    Dropdown {
        barWindow: bar
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

        // Hung off the status icons rather than placed among them: it is only
        // on screen while voxtype is recording, and a module in the row would
        // have shoved every icon to its left along the bar each time it
        // appeared.
        VoxtypeWave {
            anchors.right: status.left
            anchors.rightMargin: Config.moduleSpacing
            anchors.verticalCenter: parent.verticalCenter
        }

        Row {
            id: status

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
