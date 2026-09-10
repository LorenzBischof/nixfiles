import Quickshell

ShellRoot {
    Variants {
        model: Quickshell.screens

        Bar {}
    }

    // Not under Variants: unlike the bar there is only ever one of these, on
    // the built-in panel, and it picks that screen out itself.
    FnOverlay {}
}
