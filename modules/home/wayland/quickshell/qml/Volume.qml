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

    // Inverted, matching the natural scrolling configured for the pointers.
    onScrolled: delta => {
        if (!root.audio)
            return;
        root.audio.volume = Math.max(0, Math.min(1, root.audio.volume - (delta > 0 ? 0.05 : -0.05)));
    }

    dropdown: VolumeMenu {
        onCloseRequested: root.closeDropdown()
    }

    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }
}
