pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// What voxtype is doing, and how loud it is while doing it. Two subscriptions
// feed this: the daemon's own status stream, which runs for the life of the
// bar, and the audio-level sidecar, which only runs while there is a recording
// to draw.
//
// A singleton rather than state inside the bar module, because two things read
// it -- the module's icon and the waveform panel -- and because the module is
// per-screen: state here means one `voxtype status --follow` for the session
// rather than one per monitor.
Singleton {
    id: root

    // The daemon's last status object: text, class and tooltip, as the waybar
    // consumers take it.
    property var status: null

    // Levels oldest first, one per bar of the strip, each the loudest sample
    // of the window it covers.
    property var levels: root.silence()

    // Peak of the window being filled, and how many frames have gone into it.
    property real windowPeak: 0
    property int windowFrames: 0

    readonly property string statusText: root.status?.text ?? ""
    readonly property string tooltip: root.status?.tooltip ?? ""
    readonly property string statusClass: root.status?.class ?? ""

    // The two states that carry audio. Everything else -- transcribing, idle,
    // a daemon that is not running -- has no frames to draw, and the sidecar
    // below is only alive for these.
    readonly property bool capturing: root.statusClass === "recording" || root.statusClass === "streaming"

    // Whether there is anything to draw: the recording itself, plus the second
    // or so afterwards in which the last of it is still scrolling off.
    readonly property bool active: root.capturing || drain.running

    // One colour for the state, so the bar icon and the panel's waveform never
    // disagree about what is going on.
    readonly property color statusColor: {
        switch (root.statusClass) {
        // Streaming is the recording state for engines that transcribe as you
        // speak; it carries audio exactly like "recording" does, so it draws
        // the same and the waveform treats both alike.
        case "recording":
        case "streaming":
            return Config.alert;
        case "transcribing":
            return Config.accent;
        default:
            return Config.foreground;
        }
    }

    function silence(): var {
        return new Array(Config.waveformBars).fill(0);
    }

    function toggle(): void {
        toggleProcess.running = true;
    }

    function pushFrame(line: string): void {
        let frame;
        try {
            frame = JSON.parse(line);
        } catch (e) {
            return;
        }
        // The sidecar signals its own connection state inline on the same
        // stream; those lines carry no levels.
        if (typeof frame.peak !== "number")
            return;

        root.windowPeak = Math.max(root.windowPeak, frame.peak);
        root.windowFrames += 1;
        if (root.windowFrames < Config.waveformFramesPerBar)
            return;

        root.shift(root.windowPeak);
        root.windowPeak = 0;
        root.windowFrames = 0;
    }

    // One column along, oldest off the left end. Every bar the strip draws
    // arrives this way -- at the right, a column at a time -- so a recording
    // scrolls in rather than appearing, and the silence the drain below pushes
    // scrolls it back out the same way.
    function shift(level: real): void {
        const next = root.levels.slice(1);
        next.push(level);
        root.levels = next;
    }

    // Start and stop the sidecar on the state the status stream already
    // reports, rather than leaving a second process running for the weeks
    // between recordings.
    onCapturingChanged: {
        root.windowPeak = 0;
        root.windowFrames = 0;
        if (root.capturing) {
            // Straight to silence rather than draining what is on screen: a
            // recording starting is not the tail of the one before it.
            drain.stop();
            root.levels = root.silence();
            bridge.running = true;
        } else {
            bridgeRestart.stop();
            bridge.running = false;
            drain.start();
        }
    }

    // What is left on screen when the audio stops, pushed off the left edge at
    // the rate it arrived at. Without it the strip would blink out mid-word.
    Timer {
        id: drain

        interval: Config.waveformBarInterval
        repeat: true

        onTriggered: {
            root.shift(0);
            if (root.levels.every(level => level === 0))
                drain.stop();
        }
    }

    // voxtype streams one JSON status object per line for as long as it runs.
    Process {
        id: follow

        running: true
        command: [Config.voxtype, "status", "--follow", "--format", "json", "--icon-theme", "material"]

        stdout: SplitParser {
            onRead: line => {
                try {
                    root.status = JSON.parse(line);
                } catch (e) {
                    root.status = null;
                }
            }
        }

        onExited: restart.restart()
    }

    Timer {
        id: restart

        interval: 5000
        onTriggered: follow.running = true
    }

    Process {
        id: toggleProcess

        command: [Config.voxtype, "record", "toggle"]
    }

    // The sidecar reads the daemon's audio socket and prints one NDJSON frame
    // per 10 ms window. It reconnects to that socket on its own; the timer
    // below covers the sidecar itself dying, which would otherwise freeze the
    // waveform on its last frame for the rest of the recording.
    Process {
        id: bridge

        command: [Config.voxtypeAudioBridge]

        stdout: SplitParser {
            onRead: line => root.pushFrame(line)
        }

        onExited: {
            if (root.capturing)
                bridgeRestart.restart();
        }
    }

    Timer {
        id: bridgeRestart

        interval: 1000
        onTriggered: bridge.running = root.capturing
    }
}
