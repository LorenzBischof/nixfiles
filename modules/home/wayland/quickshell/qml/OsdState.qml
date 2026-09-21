pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// What the volume and brightness keys put on screen -- the readout wob used to
// draw, moved into the bar's own shell so it takes the stylix theme and the
// same panel chrome as everything else the bar puts up.
//
// Put up only by the sway bindings, over quickshell's IPC socket (see the `osd`
// wrapper in ../default.nix), and by scrolling the bar's volume module, rather
// than by watching the two values: an explicit adjustment is the one thing that
// should make this appear, so an app setting its own volume stays silent, and
// nothing flashes up when quickshell starts. The dropdown's own slider is
// silent too -- it draws the same level itself, right under the pointer.
//
// Volume is read back off Pipewire, which the bar already tracks and which
// carries the mute flag with it. Brightness has no such service, so the wrapper
// reads it out of brillo and passes the percentage in; the binding runs it
// after brillo's fade has finished, so the number is the one being settled on
// rather than a frame of the ramp.
Singleton {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var audio: root.sink ? root.sink.audio : null

    // Which of the two is being shown, "volume" or "brightness"; empty until
    // the first keypress. The level is 0-1, matching both Config.volumeIcon and
    // PwNodeAudio.volume.
    property string kind: ""
    property real level: 0
    property bool muted: false
    property bool shown: false

    readonly property string icon: root.kind === "volume" ? Config.volumeIcon(root.level, root.muted) : Config.brightnessIcon(root.level)

    function showVolume(): void {
        root.kind = "volume";
        root.level = root.audio?.volume ?? 0;
        root.muted = root.audio?.muted ?? false;
        root.show();
    }

    function show(): void {
        root.shown = true;
        // Restarted by hand rather than by letting `running` follow `shown`:
        // holding a key repeats while the readout is already up, and only a
        // restart keeps it there for the whole run of presses.
        hideTimer.restart();
    }

    IpcHandler {
        target: "osd"

        function volume(): void {
            root.showVolume();
        }

        function brightness(percent: real): void {
            root.kind = "brightness";
            root.level = Math.max(0, Math.min(1, percent / 100));
            root.muted = false;
            root.show();
        }
    }

    // wob's own timeout, which this replaces.
    Timer {
        id: hideTimer

        interval: 1000
        onTriggered: root.shown = false
    }

    // Without this the sink's audio properties are never bound and the volume
    // read above is whatever Pipewire happened to report at startup.
    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }
}
