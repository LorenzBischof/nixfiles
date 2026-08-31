import QtQuick

// A status icon or label, with an optional tooltip and click/scroll handling.
Item {
    id: root

    property string text: ""
    property color textColor: Config.foreground
    property string tooltipText: ""
    property int buttons: Qt.NoButton

    signal clicked(int button)
    signal scrolled(int delta)

    // Size from the advance width rather than Text's painted bounds: several of
    // the icon glyphs draw outside their advance, so using the ink would make
    // module widths jump around whenever an icon changes.
    implicitWidth: Math.round(metrics.advanceWidth) + Config.modulePadding * 2
    implicitHeight: Config.barHeight

    TextMetrics {
        id: metrics

        font: label.font
        text: root.text
    }

    BarText {
        id: label

        x: Config.modulePadding
        width: Math.round(metrics.advanceWidth)
        anchors.verticalCenter: parent.verticalCenter
        text: root.text
        color: root.textColor
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: root.buttons
        hoverEnabled: true

        onClicked: event => root.clicked(event.button)
        onWheel: wheel => root.scrolled(wheel.angleDelta.y)
        onEntered: hoverDelay.restart()
        onExited: {
            hoverDelay.stop();
            tooltip.active = false;
        }
    }

    Timer {
        id: hoverDelay

        interval: 500
        onTriggered: tooltip.active = true
    }

    Tooltip {
        id: tooltip

        target: root
        text: root.tooltipText
    }
}
