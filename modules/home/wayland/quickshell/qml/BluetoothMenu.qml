import QtQuick
import Quickshell
import Quickshell.Bluetooth

// Contents of the bluetooth dropdown: a switch for the radio, the devices this
// machine is already paired with, and -- only while a scan is running --
// whatever else is in range.
Column {
    id: root

    // Whether the dropdown is on screen. Discovery is stopped when it leaves:
    // a scan keeps the radio busy and is audible on a connected headset, so it
    // never outlives the list it was filling.
    required property bool active

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool powered: root.adapter?.enabled ?? false
    readonly property bool discovering: root.adapter?.discovering ?? false

    // Connected first, then by name. Nothing here jitters the way a wifi
    // signal does, so this list needs none of that one's pinning.
    readonly property var devices: {
        if (!root.powered)
            return [];
        return Bluetooth.devices.values.slice().sort((a, b) => {
            if (a.connected !== b.connected)
                return a.connected ? -1 : 1;
            return (a.name || a.address).localeCompare(b.name || b.address);
        });
    }

    // Paired devices are on the bus whether or not anything is scanning, and
    // are the ones reconnected day to day. Everything else exists only while
    // discovery runs, so it is listed under the switch that turned it up.
    //
    // Bonded is the property that means "there are keys to come back with",
    // but a device can finish pairing without leaving any -- a session-only
    // LE pairing does, and so does the emulator this was tested against. Such
    // a device is still not a stranger, so either flag puts it up here.
    readonly property var pairedDevices: root.devices.filter(dev => dev.bonded || dev.paired)
    readonly property var nearbyDevices: root.devices.filter(dev => !dev.bonded && !dev.paired)

    // Only one device's panel is open at a time.
    property var expandedDevice: null

    spacing: Config.menuSpacing

    onActiveChanged: {
        if (!root.active) {
            root.expandedDevice = null;
            if (root.adapter)
                root.adapter.discovering = false;
        }
    }

    BarText {
        leftPadding: Config.menuPadding
        rightPadding: Config.menuPadding
        width: parent.width
        text: "No bluetooth adapter"
        color: Config.popupTextDim
        wrapMode: Text.Wrap
        visible: root.adapter === null
    }

    MenuRow {
        width: parent.width
        visible: root.adapter !== null

        icon: root.powered ? "󰂯" : "󰂲"
        text: "Bluetooth"
        checked: root.powered
        // An rfkill hardware block cannot be undone from here, so the row says
        // so rather than offering a switch that would do nothing.
        detail: {
            switch (root.adapter?.state) {
            case BluetoothAdapterState.Blocked:
                return "blocked";
            case BluetoothAdapterState.Enabling:
                return "turning on";
            case BluetoothAdapterState.Disabling:
                return "turning off";
            default:
                return root.powered ? "on" : "off";
            }
        }
        interactive: root.adapter?.state !== BluetoothAdapterState.Blocked

        onClicked: root.adapter.enabled = !root.adapter.enabled
    }

    MenuSeparator {
        width: parent.width
        visible: root.powered
    }

    Repeater {
        // A scan can insert several delegates before Column's deferred layout
        // runs. Flush it on the next event-loop turn so the popup sees the new
        // content height rather than retaining the previous row geometry.
        onCountChanged: Qt.callLater(() => root.forceLayout())

        model: ScriptModel {
            values: root.pairedDevices
        }

        BluetoothRow {
            required property var modelData

            width: root.width
            device: modelData
            expanded: root.expandedDevice === modelData

            onExpandRequested: expand => root.expandedDevice = expand ? modelData : null
        }
    }

    BarText {
        leftPadding: Config.menuPadding
        rightPadding: Config.menuPadding
        width: parent.width
        text: "No paired devices"
        color: Config.popupTextDim
        visible: root.powered && root.pairedDevices.length === 0
    }

    MenuSeparator {
        width: parent.width
        visible: root.powered
    }

    // Discovery is a switch rather than something opening the panel starts by
    // itself, unlike the wifi list's scan: the devices worth reaching for are
    // already paired and listed above, and scanning for the rest costs the one
    // that is playing audio.
    MenuRow {
        width: parent.width
        visible: root.powered

        icon: "󰍉"
        text: "Scan for devices"
        checked: root.discovering
        detail: root.discovering ? "on" : "off"

        onClicked: root.adapter.discovering = !root.discovering
    }

    Repeater {
        onCountChanged: Qt.callLater(() => root.forceLayout())

        // Gated on the scan rather than on the list: BlueZ keeps a device it
        // has seen around for a while after discovery stops, and a stale row
        // offering to pair with something long out of range is worse than no
        // row.
        model: ScriptModel {
            values: root.discovering ? root.nearbyDevices : []
        }

        BluetoothRow {
            required property var modelData

            width: root.width
            device: modelData
            expanded: root.expandedDevice === modelData

            onExpandRequested: expand => root.expandedDevice = expand ? modelData : null
        }
    }

    // A scan takes seconds to turn up anything, so the empty list gets a row
    // saying so. MenuRow's own spinner does the work the wifi menu spells out
    // by hand.
    MenuRow {
        width: parent.width
        visible: root.discovering && root.nearbyDevices.length === 0

        text: "Scanning…"
        interactive: false
        spinning: true
    }
}
