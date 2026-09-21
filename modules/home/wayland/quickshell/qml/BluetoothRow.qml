import QtQuick
import Quickshell.Bluetooth

// One bluetooth device in the dropdown. The row alone is the whole story for a
// device that just connects; the panel under it carries the rarer decisions --
// pairing something new, letting a device reconnect on its own, forgetting one.
Column {
    id: root

    required property var device
    // Whether this row's panel is the one showing. The menu owns it so that
    // only one panel is open at a time.
    required property bool expanded

    signal expandRequested(bool expand)

    // BlueZ hands out its own name as the alias when nothing has renamed the
    // device, so the address is only reached for by the nameless.
    readonly property string label: root.device.name || root.device.address

    // Either flag means the device has been through pairing and can simply be
    // connected to; see the note in BluetoothMenu.qml.
    readonly property bool known: root.device.bonded || root.device.paired

    readonly property bool busy: root.device.pairing || root.device.state === BluetoothDeviceState.Connecting || root.device.state === BluetoothDeviceState.Disconnecting

    spacing: 0

    Connections {
        target: root.device

        // The panel's reason to be open is gone once the device is up, and the
        // row then says everything it was saying.
        function onConnectedChanged() {
            if (root.device.connected)
                root.expandRequested(false);
        }
    }

    MenuRow {
        width: parent.width

        icon: Config.bluetoothIcon(root.device.icon)
        text: root.label
        checked: root.device.connected
        spinning: root.busy
        // A connected device that reports a battery spends the detail column
        // on it; one that does not gets the same tick the wifi list uses.
        detail: {
            if (!root.device.connected)
                return "";
            return root.device.batteryAvailable ? `${Math.round(root.device.battery * 100)}%` : "󰄬";
        }

        // Left click does the obvious thing; right click opens the panel on any
        // device, which is the only way to forget one that is not connected.
        onClicked: {
            if (root.busy)
                return;
            if (root.device.connected)
                root.expandRequested(!root.expanded);
            else if (root.known)
                root.device.connect();
            else
                root.device.pair();
        }

        onRightClicked: root.expandRequested(!root.expanded)
    }

    MenuPanel {
        width: parent.width
        visible: root.expanded

        MenuRow {
            width: parent.width
            icon: "󰌘"
            text: "Connect"
            visible: root.known && !root.device.connected

            onClicked: root.device.connect()
        }

        MenuRow {
            width: parent.width
            icon: "󰌙"
            text: "Disconnect"
            visible: root.device.connected

            onClicked: {
                root.device.disconnect();
                root.expandRequested(false);
            }
        }

        MenuRow {
            width: parent.width
            icon: "󰌹"
            text: "Pair"
            visible: !root.known && !root.device.pairing

            onClicked: root.device.pair()
        }

        MenuRow {
            width: parent.width
            icon: "󰜺"
            text: "Cancel pairing"
            visible: root.device.pairing

            onClicked: root.device.cancelPair()
        }

        // BlueZ calls this "trusted": a device it accepts a connection from
        // without asking, which in practice is what lets a headset come back by
        // itself when it is switched on.
        MenuRow {
            width: parent.width
            icon: "󰕥"
            text: "Auto-reconnect"
            checked: root.device.trusted
            detail: root.device.trusted ? "on" : "off"
            visible: root.known

            onClicked: root.device.trusted = !root.device.trusted
        }

        MenuRow {
            width: parent.width
            icon: "󰆴"
            text: "Forget device"
            visible: root.known

            // Collapsed first: forgetting drops the device off the bus, and
            // the panel would otherwise be left hanging off a row that is on
            // its way out.
            onClicked: {
                root.expandRequested(false);
                root.device.forget();
            }
        }
    }
}
