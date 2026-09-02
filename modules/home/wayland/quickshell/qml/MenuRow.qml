import QtQuick

// A line in a dropdown: an icon column, a label, and an optional trailing
// detail. Used both for pickable devices and for plain actions. The row spans
// the panel edge to edge and insets its own contents, so the highlight reads as
// a full-width band rather than a floating block.
Rectangle {
    id: root

    property string icon: ""
    property string text: ""
    property string detail: ""
    property bool checked: false
    // A row that only reports something takes no clicks and does not light up
    // under the pointer, so the highlight keeps meaning "this does something".
    property bool interactive: true
    property bool spinning: false

    signal clicked
    signal rightClicked

    implicitHeight: Config.menuRowHeight
    color: mouse.containsMouse ? Config.overlay : "transparent"

    BarText {
        id: iconLabel

        anchors.left: parent.left
        anchors.leftMargin: Config.menuPadding
        anchors.verticalCenter: parent.verticalCenter
        width: Config.menuIconWidth
        horizontalAlignment: Text.AlignLeft
        text: root.icon
        color: root.checked ? Config.accent : Config.popupTextDim
    }

    BarText {
        id: detailLabel

        anchors.right: parent.right
        anchors.rightMargin: Config.menuPadding
        anchors.verticalCenter: parent.verticalCenter
        text: root.detail
        color: root.checked ? Config.accent : Config.popupTextDim
        visible: root.detail !== "" && !root.spinning
    }

    BarText {
        id: spinner

        anchors.right: parent.right
        anchors.rightMargin: Config.menuPadding
        anchors.verticalCenter: parent.verticalCenter
        width: Config.menuIconWidth
        height: Config.menuIconWidth
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "󰑐"
        color: root.checked ? Config.accent : Config.popupTextDim
        visible: root.spinning

        RotationAnimator {
            target: spinner
            from: 0
            to: 360
            duration: 1500
            loops: Animation.Infinite
            running: spinner.visible

            onRunningChanged: if (!running)
                spinner.rotation = 0
        }
    }

    BarText {
        anchors.left: iconLabel.right
        anchors.right: detailLabel.visible ? detailLabel.left : (spinner.visible ? spinner.left : parent.right)
        anchors.leftMargin: Config.menuSpacing
        anchors.rightMargin: detailLabel.visible || spinner.visible ? Config.menuSpacing : Config.menuPadding
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        elide: Text.ElideRight
        color: root.checked ? Config.popupTextStrong : Config.popupText
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        enabled: root.interactive
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor

        onClicked: event => {
            if (event.button === Qt.RightButton)
                root.rightClicked();
            else
                root.clicked();
        }
    }
}
