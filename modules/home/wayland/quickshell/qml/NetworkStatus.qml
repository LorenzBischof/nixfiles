import Quickshell.Networking

BarModule {
    id: root

    // A wired link outranks wifi when both are up, the way NetworkManager's
    // route metrics do.
    readonly property var device: {
        const connected = Networking.devices.values.filter(dev => dev.connected);
        return connected.find(dev => dev.type === DeviceType.Wired) ?? connected.find(dev => dev.type === DeviceType.Wifi) ?? null;
    }
    readonly property var network: root.device ? (root.device.networks.values.find(net => net.connected) ?? null) : null

    text: {
        if (!root.device)
            return "󰖪";
        return root.device.type === DeviceType.Wifi ? "󰖩" : "󰈀";
    }

    textColor: root.device ? Config.foreground : Config.alert

    tooltipText: {
        if (!root.device)
            return "Disconnected";
        const name = root.network?.name ?? root.device.name;
        const label = name === root.device.name ? name : `${name} (${root.device.name})`;
        if (root.device.type === DeviceType.Wifi && root.network)
            return `${label} · ${Math.round(root.network.signalStrength * 100)}%`;
        return label;
    }
}
