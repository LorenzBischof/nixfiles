import QtQuick

// A status icon or label, with an optional tooltip, dropdown and click/scroll
// handling.
Item {
    id: root

    property string text: ""
    property color textColor: Config.foreground
    property string tooltipText: ""
    property int buttons: Qt.NoButton
    // Panel opened by a left click, if set. The component is written inside the
    // module that assigns it, so it can call back into that module -- see
    // closeDropdown() below.
    property Component dropdown: null

    readonly property bool dropdownOpen: Dropdowns.owner === root

    signal clicked(int button)
    signal scrolled(int delta)

    function closeDropdown(): void {
        Dropdowns.close();
    }

    // Size from the advance width rather than Text's painted bounds: several of
    // the icon glyphs draw outside their advance, so using the ink would make
    // module widths jump around whenever an icon changes.
    implicitWidth: Math.round(metrics.advanceWidth) + Config.modulePadding * 2
    implicitHeight: Config.barHeight

    // A module with an open panel is lifted off the bar. It gets no border of
    // its own: the panel's border sits directly below the bar and already
    // breaks under this module, so a second line here would just stack onto it.
    Rectangle {
        anchors.fill: parent
        color: Config.surface
        visible: root.dropdown !== null && (root.dropdownOpen || mouse.containsMouse)
    }

    TextMetrics {
        id: metrics

        font: label.font
        text: root.text
    }

    BarText {
        id: label

        anchors.centerIn: parent
        text: root.text
        color: root.textColor
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        acceptedButtons: root.dropdown ? root.buttons | Qt.LeftButton : root.buttons
        hoverEnabled: true

        onClicked: event => {
            if (root.dropdown && event.button === Qt.LeftButton) {
                hoverDelay.stop();
                tooltip.active = false;
                Dropdowns.toggle(root);
                return;
            }
            // A module that does something else with the click still dismisses
            // whatever panel was open, the way a click anywhere else would.
            Dropdowns.close();
            root.clicked(event.button);
        }
        onWheel: wheel => root.scrolled(wheel.angleDelta.y)
        // No tooltips while a panel is open, for any module and not just the
        // one the panel hangs from: the bar keeps receiving hover now that
        // panels let it through, and a tooltip over an open panel reads as
        // part of it.
        onEntered: {
            if (!Dropdowns.owner)
                hoverDelay.restart();
        }
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
