import QtQuick

// The group of actions that unfolds under a row in a dropdown.
//
// Drawn as something cut into the panel rather than laid on it: the bar's own
// background instead of the panel's surface, and a full-height accent rail down
// the left edge. The rail is the same 5px sway border PopupSurface uses to tie a
// panel to the module it hangs from, so the grammar is already established --
// here it ties a group of actions to the row above it. Without that, a device's
// own actions sit at the same weight as the devices around it and read as more
// of them.
Rectangle {
    id: root

    default property alias content: inner.data

    implicitHeight: inner.implicitHeight
    color: Config.background

    Rectangle {
        width: Config.popupBorder
        height: parent.height
        color: Config.accent
    }

    // Offset by the rail alone. The rows keep their own side padding, so every
    // line in the group shares one left edge, one step in from the rows outside
    // it.
    Column {
        id: inner

        x: Config.popupBorder
        width: parent.width - Config.popupBorder
        spacing: 0
    }
}
