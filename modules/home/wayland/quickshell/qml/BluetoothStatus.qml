import Quickshell.Bluetooth

BarModule {
    id: root

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var connectedDevice: Bluetooth.devices.values.find(dev => dev.connected) ?? null

    // Nothing worth showing without a powered adapter.
    visible: root.adapter !== null && root.adapter.enabled

    text: root.connectedDevice ? "󰂱" : "󰂯"
    tooltipText: root.connectedDevice ? root.connectedDevice.name : "Not connected"
}
