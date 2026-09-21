pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Pipewire

BarModule {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var audio: sink ? sink.audio : null
    readonly property bool muted: audio ? audio.muted : false
    // PwNodeAudio.volume is already on PulseAudio's cubic scale, so it is the
    // same number pavucontrol shows.
    readonly property int volume: audio ? Math.round(audio.volume * 100) : 0

    visible: root.audio !== null
    buttons: Qt.MiddleButton

    text: Config.volumeIcon(root.audio?.volume ?? 0, root.muted)
    textColor: root.muted ? Config.alert : Config.foreground
    tooltipText: root.muted ? "Muted" : `${root.volume}%`

    onClicked: button => {
        if (button === Qt.MiddleButton && root.audio)
            root.audio.muted = !root.audio.muted;
    }

    // Inverted, matching the natural scrolling configured for the pointers. One
    // notch is 5%, the step the volume keys take, and the result is snapped to
    // that grid so a scroll always lands on a round percentage however the
    // volume was set before.
    onScrolled: steps => {
        if (!root.audio)
            return;
        root.audio.volume = Math.max(0, Math.min(1, Math.round(root.audio.volume * 20 - steps) / 20));
        // Same readout the volume keys put up: while adjusting from the bar the
        // pointer is on the icon, which is the one thing covering the module's
        // own tooltip.
        OsdState.showVolume();
    }

    dropdown: VolumeMenu {
        onCloseRequested: root.closeDropdown()
    }

    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }
}
