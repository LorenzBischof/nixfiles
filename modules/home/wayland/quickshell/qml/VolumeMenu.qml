import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire

// Contents of the volume dropdown: a level for the default output and input,
// and a picker for each whenever there is more than one device to choose from.
Column {
    id: root

    signal closeRequested

    readonly property var sinks: Pipewire.nodes.values.filter(node => node.type === PwNodeType.AudioSink)
    readonly property var sources: Pipewire.nodes.values.filter(node => node.type === PwNodeType.AudioSource)
    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource

    function label(node: var): string {
        return node.description || node.nickname || node.name;
    }

    spacing: Config.menuSpacing

    // Volume and mute state are only streamed in for tracked nodes, and the
    // pickers show a level for every device, not just the default one.
    PwObjectTracker {
        objects: root.sinks.concat(root.sources)
    }

    MenuHeading {
        text: "Output"
    }

    MenuSlider {
        width: parent.width
        visible: root.sink !== null

        icon: Config.volumeIcon(root.sink?.audio?.volume ?? 0, root.sink?.audio?.muted ?? false)
        iconColor: root.sink?.audio?.muted ? Config.alert : Config.popupText
        value: root.sink?.audio?.volume ?? 0
        dimmed: root.sink?.audio?.muted ?? false

        onMoved: value => {
            if (root.sink?.audio)
                root.sink.audio.volume = value;
        }

        onIconClicked: {
            if (root.sink?.audio)
                root.sink.audio.muted = !root.sink.audio.muted;
        }
    }

    // A single device is not worth a picker; the level above already says which.
    Repeater {
        model: root.sinks.length > 1 ? root.sinks : []

        MenuRow {
            required property var modelData

            width: root.width
            icon: modelData === root.sink ? "󰄬" : ""
            text: root.label(modelData)
            checked: modelData === root.sink

            onClicked: Pipewire.preferredDefaultAudioSink = modelData
        }
    }

    MenuSeparator {
        width: parent.width
        visible: root.source !== null
    }

    MenuHeading {
        text: "Input"
        visible: root.source !== null
    }

    MenuSlider {
        width: parent.width
        visible: root.source !== null

        icon: root.source?.audio?.muted ? "󰍭" : "󰍬"
        iconColor: root.source?.audio?.muted ? Config.alert : Config.popupText
        value: root.source?.audio?.volume ?? 0
        dimmed: root.source?.audio?.muted ?? false

        onMoved: value => {
            if (root.source?.audio)
                root.source.audio.volume = value;
        }

        onIconClicked: {
            if (root.source?.audio)
                root.source.audio.muted = !root.source.audio.muted;
        }
    }

    Repeater {
        model: root.sources.length > 1 ? root.sources : []

        MenuRow {
            required property var modelData

            width: root.width
            icon: modelData === root.source ? "󰄬" : ""
            text: root.label(modelData)
            checked: modelData === root.source

            onClicked: Pipewire.preferredDefaultAudioSource = modelData
        }
    }

    MenuSeparator {
        width: parent.width
    }

    MenuRow {
        width: parent.width
        icon: "󰒓"
        text: "Sound settings"

        onClicked: {
            pavucontrol.running = true;
            root.closeRequested();
        }
    }

    Process {
        id: pavucontrol

        command: [Config.pavucontrol]
    }
}
