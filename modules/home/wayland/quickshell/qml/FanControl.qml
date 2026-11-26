pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// fw-fanctrl's part of the battery dropdown: the fan duty it last set, the
// hottest sensor right now, and which strategy picks the duty. The curve itself
// runs on a moving average, so the duty can lag a spike in the temperature.
// Absent on a machine without fw-fanctrl, and while the service cannot be
// reached.
//
// Polled, and only while the dropdown is open: fw-fanctrl publishes nothing to
// subscribe to -- it runs `--silent`, and its socket answers questions rather
// than announcing changes -- and the duty and temperature move every few
// seconds anyway, which is the point of looking.
Column {
    id: root

    required property bool active

    // `print` with no selection is the whole state in one answer.
    property var status: null

    readonly property bool automatic: root.status?.default ?? true
    // In the order the configuration lists them, which is the shipped
    // laziest-to-loudest order with any of our own after.
    readonly property var strategies: Object.keys(root.status?.configuration?.data?.strategies ?? {})

    function run(args: var): void {
        if (action.running)
            return;
        action.command = [Config.fwFanctrl, ...args];
        action.running = true;
    }

    visible: root.status !== null
    spacing: Config.menuSpacing

    Process {
        id: query

        command: [Config.fwFanctrl, "--output-format", "JSON", "print"]

        // A daemon that is down leaves stdout empty, which fails the parse
        // just as an error reply fails the status check: either way the
        // section goes rather than showing numbers nothing stands behind.
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const reply = JSON.parse(this.text);
                    root.status = reply.status === "success" ? reply : null;
                } catch (e) {
                    root.status = null;
                }
            }
        }
    }

    Process {
        id: action

        // Re-read so the tick moves at once. The duty follows on the daemon's
        // next tick, and the timer picks that up.
        onExited: query.running = true
    }

    // The speed is set every 5 s by the shipped strategies and the temperature
    // sampled every second, so 2 s keeps both within a beat of the hardware.
    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: root.active && Config.fwFanctrl !== ""
        onTriggered: query.running = true
    }

    MenuSeparator {
        width: parent.width
    }

    MenuHeading {
        text: "Fan"
    }

    MenuRow {
        width: parent.width
        icon: "󰈐"
        text: "Speed"
        detail: `${root.status?.speed ?? 0}%`
        interactive: false
    }

    MenuRow {
        width: parent.width
        icon: "󰔏"
        text: "Temperature"
        detail: `${Math.round(root.status?.temperature ?? 0)}°C`
        interactive: false
    }

    // Back to the configured default, which itself follows the charger:
    // defaultStrategy on AC, strategyOnDischarging on battery. The strategy it
    // has settled on is named alongside, since that is what the fan is doing.
    MenuRow {
        width: parent.width
        icon: "󱜝"
        text: "Automatic"
        checked: root.automatic
        detail: root.automatic ? (root.status?.strategy ?? "") : ""

        onClicked: root.run(["reset"])
    }

    Repeater {
        model: root.strategies

        MenuRow {
            required property string modelData

            readonly property bool current: !root.automatic && root.status?.strategy === modelData

            width: root.width
            text: modelData
            checked: current
            detail: current ? "󰄬" : ""

            onClicked: root.run(["use", modelData])
        }
    }
}
