import QtQuick
import Quickshell.Io
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
    buttons: Qt.LeftButton

    text: {
        if (root.muted)
            return "󰝟";
        if (root.volume === 0)
            return "󰝞";
        const icons = Config.volumeIcons;
        return icons[Math.min(icons.length - 1, Math.floor(root.volume / 34))];
    }

    textColor: root.muted ? Config.alert : Config.foreground
    tooltipText: root.muted ? "Muted" : `${root.volume}%`

    onClicked: pavucontrol.running = true

    // Inverted, matching the natural scrolling configured for the pointers.
    onScrolled: delta => {
        if (!root.audio)
            return;
        root.audio.volume = Math.max(0, Math.min(1, root.audio.volume - (delta > 0 ? 0.05 : -0.05)));
    }

    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    Process {
        id: pavucontrol

        command: [Config.pavucontrol]
    }
}
