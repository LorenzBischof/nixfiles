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

    property int toastCount: 0
    // Room below the stack for a toast on its way out. A departing one barely
    // lifts now (NotificationToast.exitLift), so it overhangs its own
    // collapsing slot instead of riding up out of it, and the window edge would
    // cut that overhang square while it is still faintly visible.
    readonly property int animationPadding: 48
    readonly property int toastTop: Config.barHeight + Config.edgeMargin

    color: "transparent"
    // Counted explicitly rather than measured off the column: a positioner
    // lays out on polish and polish only runs for a window that is rendering,
    // so a `visible` taken from the column's height would never come true --
    // the column stays zero high until the window is up, and the window waits
    // on the column. Dropdown.qml hits the same trap from the other side.
    visible: root.toastCount > 0
    implicitWidth: Config.notificationWidth
    // Keep the window tall enough for the moving toasts until they settle.
    implicitHeight: root.toastTop + root.animationPadding + Math.max(1, column.implicitHeight, column.childrenRect.y + column.childrenRect.height)

    // Leave room to paint the vertical transitions, without making that
    // transparent padding intercept clicks intended for the desktop.
    mask: Region {
        y: column.y
        width: column.width
        height: Math.max(column.implicitHeight, column.childrenRect.y + column.childrenRect.height)
    }

    // Start the overlay at the screen edge so departing toasts can pass over
    // the bar. The column positions resting toasts a small gap below it.
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "quickshell-notifications"

    anchors {
        top: true
        right: true
    }

    margins {
        top: 0
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
            toastComponent.createObject(column, { notification });
            root.toastCount++;
        }
    }

    Column {
        id: column
        y: root.toastTop

        // Sized off the same constant the window is rather than off `parent`.
        // A window that is down has a zero-wide content item, so a toast
        // measured against it wraps its text to nothing and reports a height of
        // one line -- which is the height the window would then map at, since
        // the first toast of a stack is what brings it up. Everything here is
        // one fixed width regardless, so there is nothing to inherit.
        width: Config.notificationWidth
        // New toasts arrive below the ones already up: an arrival never moves
        // a toast that is being read.
        //
        // No gap between them. The window is exactly this column, so a
        // transparent strip between two slabs would be a hole in it that
        // swallows clicks meant for the window behind -- and two abutting
        // hairlines read as the separator the gap was for.
        spacing: 0

    }

    // Own each visual until its exit finishes, after the server closes it.
    Component {
        id: toastComponent

        Item {
            id: slot

            required property Notification notification

            width: column.width
            // Share the toast's exit progress instead of starting a second
            // layout animation: both move the same distance on every frame.
            implicitHeight: toast.implicitHeight * (1 - toast.exitProgress)
            // A departing middle toast passes behind the one above it.
            z: toast.closing ? -1 : 0

            NotificationToast {
                id: toast

                notification: slot.notification
                width: slot.width
                onExitFinished: {
                    root.toastCount--;
                    slot.destroy();
                }
            }
        }
    }
}
