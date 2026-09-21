import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Widgets

// One notification, drawn as a slab in the same chrome every panel hanging off
// the bar wears. The rail down the left edge is MenuPanel's grammar -- the 5px
// sway border that ties a block to what it belongs to -- carrying here the one
// thing a toast says before it is read: low, normal or critical.
PopupSurface {
    id: root

    required property Notification notification

    // Milliseconds before the toast leaves on its own. The sender's own timeout
    // wins; with none, a critical notification stays until it is clicked away,
    // which is what dunst did with it.
    //
    // Milliseconds because that is what `expireTimeout` carries: the sender's
    // own `expire_timeout` argument, unconverted, whatever unit the docs name
    // for it. Read as seconds it held a sender asking for 3000 for fifty
    // minutes, which is the shape the bug took -- everything this machine sends
    // itself names no timeout and left on time, while anything that named one
    // stayed up.
    readonly property real timeoutMs: root.notification.expireTimeout > 0 ? root.notification.expireTimeout : root.notification.urgency === NotificationUrgency.Critical ? 0 : Config.notificationTimeout * 1000

    // The sender's own icon, where it has one, and the empty string where it
    // does not -- which is what puts the urgency mark in the icon column
    // instead.
    //
    // Everything arrives on `image`: quickshell folds the app icon in with the
    // image hint and hands both over as one url for its own icon provider,
    // leaving `appIcon` empty. That provider answers a name it cannot resolve
    // with a magenta placeholder rather than with a failure, so an icon this
    // machine has no file for -- `--icon=system-reboot`, which nothing here
    // provides -- would sit in the column as a checkerboard with no
    // `Image.Error` to catch it.
    //
    // So the url is unwrapped and each half is asked the question it can
    // actually answer: whether the icon theme has a name, and, for a file, Qt
    // itself, which does report Image.Error for one that is not there.
    readonly property string iconSource: {
        const prefix = "image://icon/";
        const image = root.notification.image;
        if (!image.startsWith(prefix))
            return image;
        const name = image.slice(prefix.length);
        if (name.startsWith("/"))
            return "file://" + name;
        return Quickshell.hasThemeIcon(name) ? image : "";
    }

    implicitHeight: lines.implicitHeight + Config.menuPadding * 2 + Config.popupOutline * 2

    Rectangle {
        width: Config.popupBorder
        height: parent.height
        color: Config.notificationAccent(root.notification.urgency)
    }

    // Icon column, label, the same two columns a dropdown row has -- so a toast
    // and the menus read off one grid even though nothing lines them up.
    //
    // The sender's icon when it ships one that resolves, the urgency mark when
    // it does not, which is every notification this machine sends itself. The
    // box is one line of text tall either way, so a toast with an icon is no
    // taller than one without and both sit on the summary's first line.
    Item {
        id: mark

        x: Config.popupBorder + Config.menuPadding
        y: Config.menuPadding
        width: Config.menuIconWidth
        height: Config.notificationIconSize

        IconImage {
            id: icon

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            implicitSize: Config.notificationIconSize
            source: root.iconSource
            // A path the sender made up is not worth a blank column, so a load
            // that fails hands the box back to the mark below.
            visible: root.iconSource !== "" && icon.status !== Image.Error
        }

        BarText {
            anchors.fill: parent
            verticalAlignment: Text.AlignVCenter
            text: Config.notificationIcon(root.notification.urgency)
            color: Config.notificationAccent(root.notification.urgency)
            visible: !icon.visible
        }
    }

    Column {
        id: lines

        anchors.left: mark.right
        anchors.leftMargin: Config.menuSpacing
        anchors.right: parent.right
        anchors.rightMargin: Config.menuPadding
        y: Config.menuPadding
        spacing: Config.menuSpacing

        // The server tells senders that markup is refused, and BarText pins
        // every label in the bar to plain text regardless -- so a body that
        // arrives with tags in it is a sender ignoring the answer, and its
        // tags are printed rather than painted.
        //
        // Wrapped rather than elided on the first line: plenty of what this
        // machine sends itself is a whole sentence with no body under it, and
        // cutting that at the panel edge loses the half that says what
        // happened. Two lines, then it is elided after all.
        BarText {
            width: parent.width
            text: root.notification.summary
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: Config.popupTextStrong
        }

        BarText {
            width: parent.width
            text: root.notification.body
            wrapMode: Text.Wrap
            maximumLineCount: Config.notificationBodyLines
            elide: Text.ElideRight
            color: Config.popupText
            visible: root.notification.body !== ""
        }
    }

    // Anywhere on the toast dismisses it, and says so to the sender -- an
    // explicit close rather than the timeout below.
    MouseArea {
        id: mouse

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

        onClicked: root.notification.dismiss()
    }

    // The pointer holds the toast: reading a long body should not race its
    // timer. Leaving restarts the wait from the top rather than resuming it,
    // which is the friendlier of the two and is what a Timer does anyway.
    Timer {
        interval: root.timeoutMs
        running: root.timeoutMs > 0 && !mouse.containsMouse
        onTriggered: root.notification.expire()
    }
}
