import QtQuick

// Chrome shared by everything that hangs off the bar. The edge meeting the bar
// carries a full-width sway window border in the unfocused grey, lit in the
// focused accent only under the module it belongs to -- so the module and its
// panel share one border line, the way two tiled windows do. The remaining
// edges stay a hairline: a 5px ring reads as a slab at this size.
Rectangle {
    id: root

    // Whether this panel is anchored to a module, and so gets the shared
    // border. Tooltips are transient and do without.
    property bool accentEdge: false
    // Where the owning module sits along the top edge, in this panel's own
    // coordinates. The border runs directly under the bar, so this segment
    // lands right below the module it belongs to.
    property real markerX: 0
    property real markerWidth: 0

    default property alias content: surface.data

    readonly property int topInset: root.accentEdge ? Config.popupBorder : Config.popupOutline

    color: Config.surface
    border.width: Config.popupOutline
    border.color: Config.overlay

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Config.popupBorder
        color: Config.unfocused
        visible: root.accentEdge

        Rectangle {
            x: root.markerX
            width: root.markerWidth
            height: parent.height
            color: Config.accent
        }
    }

    Item {
        id: surface

        anchors.fill: parent
        anchors.margins: Config.popupOutline
        anchors.topMargin: root.topInset
    }
}
