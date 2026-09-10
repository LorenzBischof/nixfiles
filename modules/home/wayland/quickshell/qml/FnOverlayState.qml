pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Whether the F-row legend is on screen. A tap of Right-Ctrl puts it up, and it
// takes itself back down a few seconds later; a second tap dismisses it early.
//
// The Fn key cannot drive this, because the host never learns it was pressed.
// Framework's EC recognises it by scancode in keyboard_scancode_callback, sets
// its own FN_PRESSED flag, and returns EC_ERROR_UNIMPLEMENTED -- the EC's "do
// not forward this to the host" -- so not one evdev device on the machine even
// advertises KEY_FN. Remapping Fn's matrix cell with `framework_tool
// --remap-key` would make the host see it, but the same scancode comparison is
// what marks it as Fn, so it would stop being a modifier at all. Right-Ctrl
// stands in, bound in sway (see wayland/default.nix), which calls in here over
// quickshell's IPC socket.
//
// Tapping rather than holding means only the press binding is needed, which
// also steps around sway dropping a `--release` binding for good once another
// key is pressed during the hold: Right-Ctrl used as a real modifier delivers
// the press and never the release. It still delivers that press, so a
// Right-Ctrl chord does put the legend up for its few seconds -- tap again to
// clear it.
Singleton {
    id: root

    property bool shown: false

    // `open` and `close` rather than the obvious `show` and `hide`: `qs ipc
    // call` takes the function name as a positional, and CLI11 resolves a
    // positional that matches a sibling subcommand as that subcommand instead.
    // `show` is one of them (alongside call, wait, listen and prop), so
    // `ipc call fnOverlay show` silently prints this target's function list
    // and exits 0 without ever calling anything.
    IpcHandler {
        target: "fnOverlay"

        function open(): void {
            root.shown = true;
        }

        function close(): void {
            root.shown = false;
        }

        function toggle(): void {
            root.shown = !root.shown;
        }
    }

    // Long enough to find the key you were after, short enough that a stray
    // Right-Ctrl chord is not left sitting over your windows. Restarts from
    // scratch on every fresh tap, since `running` follows `shown`.
    Timer {
        running: root.shown
        interval: 5000
        onTriggered: root.shown = false
    }
}
