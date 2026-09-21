import Quickshell

ShellRoot {
    Variants {
        model: Quickshell.screens

        Bar {}
    }

    // Not under Variants: unlike the bar there is only ever one of these, on
    // the built-in panel, and it picks that screen out itself.
    FnOverlay {}

    // Also one only, but on whichever screen has focus rather than a fixed
    // one, which it leaves to the compositor.
    Osd {}

    // Likewise. Also the notification daemon itself, so it lives here rather
    // than under a module: the bar draws nothing for it.
    NotificationPopups {}
}
