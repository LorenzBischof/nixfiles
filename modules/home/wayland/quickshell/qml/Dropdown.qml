import QtQuick
import Quickshell
import Quickshell.Wayland

// The one panel a bar shows: a transparent screen-sized input host with a
// content-sized panel hanging from whichever module currently owns it.
//
// One window per bar rather than one per module, so handing the panel from one
// module to the next only moves it and swaps its contents while the window
// stays mapped. Keeping the visible panel as an Item also avoids resizing an
// xdg-popup while it is mapped, which can leave its buffer and input geometry
// out of sync on Sway. The host provides click-outside-to-close behavior.
PanelWindow {
    id: root

    // The bar this hangs under. Gives the panel the screen it belongs on, the
    // width it has to stay inside, and the modules it will accept an owner
    // from.
    required property var barWindow

    // The module showing its panel here, or null while the open one belongs to
    // another screen's bar.
    readonly property Item owner: Dropdowns.owner && Dropdowns.owner.QsWindow.window === root.barWindow ? Dropdowns.owner : null

    visible: false
    screen: root.barWindow.screen
    color: "transparent"

    anchors {
        top: true
        left: true
        right: true
        bottom: true
    }

    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    WlrLayershell.namespace: "quickshell-dropdown"

    // Everything but the bar is ours to catch outside clicks in; `Xor` inverts
    // the region, so the strip named here is the part that passes through.
    // Without it a click on another module lands on this window instead of the
    // bar, which closed this panel and left the other one to a second click.
    //
    // Measured off the bar rather than off this window: a freshly mapped layer
    // surface is 0 wide until the compositor configures it, and a zero-width
    // strip inverts to "the whole screen", so the bar would be deaf to clicks
    // for the first frames of every open.
    mask: Region {
        width: root.barWindow.width
        height: Config.barHeight
        intersection: Intersection.Xor
    }

    // Where the owning module sits along the bar, and where that puts the
    // panel. Latched by the handler below rather than bound: mapToItem is a
    // function call that depends on nothing, so a binding needs `owner` among
    // its dependencies merely to be re-read -- and then evaluates a pass after
    // the panel is already on screen, which shows as it jumping into place.
    property real targetX: 0
    property real targetWidth: 0
    // Clamped to the bar's own edge margin so no compositor slide adjustment is
    // needed. The panel marks its own top edge under the module it belongs to,
    // and a slide it was never told about would put that mark in the wrong
    // place.
    property real panelX: 0

    onOwnerChanged: {
        if (!root.owner) {
            root.visible = false;
            return;
        }
        // Contents first: they are what the panel's height is measured from,
        // and content that sizes itself off being open -- the wifi list grows a
        // scanning row -- has to have done so before any of this is drawn.
        loader.sourceComponent = root.owner.dropdown;
        root.targetX = root.owner.mapToItem(null, 0, 0).x;
        root.targetWidth = root.owner.width;
        root.panelX = Math.max(Config.edgeMargin, Math.min(root.barWindow.width - Config.menuWidth - Config.edgeMargin, root.targetX + root.targetWidth / 2 - Config.menuWidth / 2));
        // Positioners lay out on polish, and polish only runs for a window that
        // is rendering, so content that grew while the panel was closed would
        // otherwise keep its old height until a frame after the panel appears.
        if (loader.item && loader.item.forceLayout)
            loader.item.forceLayout();
        root.visible = true;
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onClicked: Dropdowns.close()
    }

    PopupSurface {
        x: root.panelX
        y: Config.barHeight
        width: Config.menuWidth
        height: Math.max(1, loader.height + Config.menuPadding * 2 + Config.popupBorder + Config.popupOutline)
        accentEdge: true
        markerX: root.targetX - root.panelX
        markerWidth: root.targetWidth

        // Consume clicks on the panel chrome so the screen-sized handler behind
        // it only closes for clicks outside the visible popup.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        }

        // Assigned by the handler above rather than bound, so the contents are
        // in place before anything measured off them is read. Left loaded on
        // close: reopening the same module then costs nothing, and only a
        // handover to a different one rebuilds.
        Loader {
            id: loader

            y: Config.menuPadding
            // Width from the panel rather than the content, so children are free
            // to size themselves off `parent.width` without a binding loop. Full
            // width rather than inset, so a row's hover highlight and a
            // separator's hairline reach both edges; the side padding is carried
            // by the rows themselves.
            width: parent.width
        }
    }
}
