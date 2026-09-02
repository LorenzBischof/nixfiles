import QtQuick
import QtQuick.Controls.Basic

// An "icon · slider · percentage" row. The icon doubles as a button, which the
// volume rows use for muting. Like MenuRow, the row spans the panel and insets
// its own contents.
Item {
    id: root

    property string icon: ""
    property color iconColor: Config.popupText
    property real value: 0
    property bool dimmed: false

    // The filled groove and the handle, one step brighter while the slider is
    // under the pointer: enough to say it is grabbable, not enough to read as a
    // second accent.
    readonly property color fillColor: root.dimmed ? Config.subtle : Config.accent
    readonly property color activeColor: slider.hovered || slider.pressed ? Qt.lighter(root.fillColor, 1.2) : root.fillColor

    signal moved(real value)
    signal iconClicked

    implicitHeight: Config.menuRowHeight

    // Assigned rather than bound: dragging the handle writes `value` itself,
    // which would drop a binding for good.
    Binding {
        target: slider
        property: "value"
        value: root.value
        when: !slider.pressed
        restoreMode: Binding.RestoreNone
    }

    BarText {
        id: iconLabel

        anchors.left: parent.left
        anchors.leftMargin: Config.menuPadding
        anchors.verticalCenter: parent.verticalCenter
        width: Config.menuIconWidth
        horizontalAlignment: Text.AlignLeft
        text: root.icon
        color: root.iconColor

        MouseArea {
            anchors.fill: parent
            anchors.margins: -Config.menuSpacing
            cursorShape: Qt.PointingHandCursor
            onClicked: root.iconClicked()
        }
    }

    BarText {
        id: valueLabel

        anchors.right: parent.right
        anchors.rightMargin: Config.menuPadding
        anchors.verticalCenter: parent.verticalCenter
        width: Config.menuValueWidth
        horizontalAlignment: Text.AlignRight
        text: `${Math.round(root.value * 100)}%`
        color: Config.popupTextDim
    }

    Slider {
        id: slider

        anchors.left: iconLabel.right
        anchors.right: valueLabel.left
        anchors.leftMargin: Config.menuSpacing
        anchors.rightMargin: Config.menuSpacing
        anchors.verticalCenter: parent.verticalCenter

        from: 0
        to: 1
        hoverEnabled: true

        onMoved: root.moved(slider.value)

        // Square, like every other surface in the session: a flat groove with a
        // fader block riding on it.
        background: Rectangle {
            x: slider.leftPadding
            y: slider.topPadding + (slider.availableHeight - height) / 2
            width: slider.availableWidth
            height: Config.menuGrooveHeight
            color: slider.hovered ? Config.subtle : Config.overlay

            Rectangle {
                width: slider.visualPosition * parent.width
                height: parent.height
                color: root.activeColor
            }
        }

        handle: Rectangle {
            x: slider.leftPadding + slider.visualPosition * (slider.availableWidth - width)
            y: slider.topPadding + (slider.availableHeight - height) / 2
            implicitWidth: Config.menuHandleWidth
            implicitHeight: Config.menuHandleHeight
            color: root.activeColor
        }
    }
}
