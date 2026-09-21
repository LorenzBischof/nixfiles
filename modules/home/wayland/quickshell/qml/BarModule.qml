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
    // Whole wheel notches, positive for scrolling up; see onWheel below.
    signal scrolled(int steps)

    // A mouse wheel sends one notch -- 120 eighths of a degree -- per click,
    // but a touchpad reports the same gesture as a stream of much smaller
    // deltas, so acting on every event makes anything bound to the wheel race
    // away under a finger. Accumulate the angle here and emit whole notches
    // only, which puts both pointers on the same scale.
    property int wheelAngle: 0

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
        onWheel: wheel => {
            // One scroll arrives as several frames, and the ones that only
            // name the axis or mark the end of the gesture carry no angle.
            // Leaving early keeps those from reading as a reversal below and
            // throwing away what has been accumulated so far.
            if (wheel.angleDelta.y === 0)
                return;
            // A reversal starts from zero rather than spending what is left
            // over from the other direction first.
            if ((wheel.angleDelta.y > 0) !== (root.wheelAngle > 0))
                root.wheelAngle = 0;
            root.wheelAngle += wheel.angleDelta.y;
            const steps = Math.trunc(root.wheelAngle / 120);
            if (steps === 0)
                return;
            root.wheelAngle -= steps * 120;
            root.scrolled(steps);
        }
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
