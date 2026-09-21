import QtQuick
import Quickshell.Bluetooth

BarModule {
    id: root

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool powered: root.adapter?.enabled ?? false
    // Every connected device rather than just the first: a headset and a mouse
    // are both worth naming, and the tooltip is the only place they fit.
    readonly property var connected: Bluetooth.devices.values.filter(dev => dev.connected)

    // A machine with no adapter has no bluetooth to report. A powered-down one
    // keeps its module: the dropdown is the only switch for the radio.
    visible: root.adapter !== null

    text: {
        if (!root.powered)
            return "󰂲";
        return root.connected.length > 0 ? "󰂱" : "󰂯";
    }

    // A dark radio is a resting state rather than a fault -- nothing here is
    // expected to stay connected the way the network is -- so it dims instead
    // of alerting.
    textColor: root.powered ? Config.foreground : Config.subtle

    tooltipText: {
        if (root.adapter?.state === BluetoothAdapterState.Blocked)
            return "Bluetooth blocked";
        if (!root.powered)
            return "Bluetooth off";
        if (root.connected.length === 0)
            return "Not connected";
        return root.connected.map(dev => {
            const name = dev.name || dev.address;
            return dev.batteryAvailable ? `${name} · ${Math.round(dev.battery * 100)}%` : name;
        }).join(", ");
    }

    dropdown: BluetoothMenu {
        active: root.dropdownOpen
    }
}
