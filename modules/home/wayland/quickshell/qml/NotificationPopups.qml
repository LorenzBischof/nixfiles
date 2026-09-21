pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Notifications

// The freedesktop notification daemon, and the toasts it puts on screen. This
// is the whole of it: there is no history and no tray, so a notification lives
// exactly as long as its popup does.
//
// One window rather than one per screen. As with the OSD, leaving `screen`
// unset hands the placement to sway, which maps the layer surface on the
// focused output -- so a notification arrives where you are looking instead of
// on whichever monitor was enumerated first.
PanelWindow {
    id: root

    color: "transparent"
    // Counted off the model rather than measured off the column: a positioner
    // lays out on polish and polish only runs for a window that is rendering,
    // so a `visible` taken from the column's height would never come true --
    // the column stays zero high until the window is up, and the window waits
    // on the column. Dropdown.qml hits the same trap from the other side.
    visible: server.trackedNotifications.values.length > 0
    implicitWidth: Config.notificationWidth
    implicitHeight: Math.max(1, column.implicitHeight)

    // Over the windows and taking no space from them. Ignoring exclusion zones
    // also means the compositor will not push this below the bar for us, hence
    // the top margin: it is the bar's own height, so the first toast's top edge
    // meets the bar's bottom the way a dropdown's does.
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-notifications"

    anchors {
        top: true
        right: true
    }

    margins {
        top: Config.barHeight
        right: Config.edgeMargin
    }

    NotificationServer {
        id: server

        // Exactly what a toast can show, and nothing more: no action buttons,
        // no inline reply, no markup or images in the body. A sender that asks
        // is told no here and sends plain text, instead of having its tags
        // painted literally. The image hint is the exception -- a toast draws
        // it in its icon column.
        actionsSupported: false
        actionIconsSupported: false
        inlineReplySupported: false
        bodySupported: true
        bodyMarkupSupported: false
        bodyHyperlinksSupported: false
        bodyImagesSupported: false
        imageSupported: true
        // Nothing outlives the popup, so a sender must not be promised that its
        // notification will still be somewhere once the toast has gone.
        persistenceSupported: false

        // A notification is dropped the moment this handler returns unless it
        // is claimed here. The claim does not reach trackedNotifications until
        // after the handler returns, so there is nothing to measure or lay out
        // from in here.
        onNotification: notification => {
            notification.tracked = true;
        }
    }

    Column {
        id: column

        // Sized off the same constant the window is rather than off `parent`.
        // A window that is down has a zero-wide content item, so a toast
        // measured against it wraps its text to nothing and reports a height of
        // one line -- which is the height the window would then map at, since
        // the first toast of a stack is what brings it up. Everything here is
        // one fixed width regardless, so there is nothing to inherit.
        width: Config.notificationWidth
        // New toasts arrive below the ones already up, which is the model's own
        // order: an arrival then never moves a toast that is being read.
        //
        // No gap between them. The window is exactly this column, so a
        // transparent strip between two slabs would be a hole in it that
        // swallows clicks meant for the window behind -- and two abutting
        // hairlines read as the separator the gap was for.
        spacing: 0

        // The model rather than an array copied out of it: a Repeater over a
        // fresh array rebuilds every delegate whenever one notification
        // arrives, which would restart the timers of all the toasts already up.
        Repeater {
            model: server.trackedNotifications

            NotificationToast {
                required property var modelData

                width: column.width
                notification: modelData
            }
        }
    }
}
