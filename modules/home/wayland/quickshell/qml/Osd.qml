import QtQuick
import Quickshell
import Quickshell.Wayland

// The volume and brightness readout: an icon, the level as a groove, and the
// percentage -- the same three columns as a MenuSlider row, so a level looks
// the same here as it does in the volume dropdown.
PanelWindow {
    id: root

    // No `screen` and no anchors. With no screen set quickshell lets the
    // compositor place the layer surface, and sway puts it on the focused
    // output -- the one whose keys were just pressed. Anchoring to no edge
    // leaves it centred there, which is where wob sat and so where the eye
    // already expects it. It also keeps it clear of the Fn legend, which owns
    // the bottom edge.
    color: "transparent"
    visible: OsdState.shown
    implicitWidth: Config.menuWidth
    implicitHeight: Config.menuRowHeight + Config.menuPadding * 2

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Nothing here is clickable and it appears over whatever is being worked
    // in, so an empty mask makes the whole surface pointer-through.
    mask: Region {}

    PopupSurface {
        anchors.fill: parent

        BarText {
            id: icon

            anchors.left: parent.left
            anchors.leftMargin: Config.menuPadding
            anchors.verticalCenter: parent.verticalCenter
            width: Config.menuIconWidth
            horizontalAlignment: Text.AlignLeft
            text: OsdState.icon
            color: OsdState.muted ? Config.alert : Config.popupText
        }

        BarText {
            id: value

            anchors.right: parent.right
            anchors.rightMargin: Config.menuPadding
            anchors.verticalCenter: parent.verticalCenter
            width: Config.menuValueWidth
            horizontalAlignment: Text.AlignRight
            text: `${Math.round(OsdState.level * 100)}%`
            color: Config.popupTextDim
        }

        // The groove and its fill, at MenuSlider's dimensions and colours minus
        // the handle: there is nothing to grab here.
        Rectangle {
            anchors.left: icon.right
            anchors.right: value.left
            anchors.leftMargin: Config.menuSpacing
            anchors.rightMargin: Config.menuSpacing
            anchors.verticalCenter: parent.verticalCenter
            height: Config.menuGrooveHeight
            color: Config.overlay

            Rectangle {
                width: Math.max(0, Math.min(1, OsdState.level)) * parent.width
                height: parent.height
                // Muted is the one state where the level is still worth
                // showing but no longer in effect, so it drops to the same
                // grey MenuSlider uses for a dimmed row.
                color: OsdState.muted ? Config.subtle : Config.accent
            }
        }
    }
}
