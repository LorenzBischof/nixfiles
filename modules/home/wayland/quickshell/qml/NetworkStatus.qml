import QtQuick
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

    readonly property var connectingDevice: Networking.devices.values.find(dev => dev.state === ConnectionState.Connecting) ?? null
    readonly property bool activelyConnecting: !root.device && root.connectingDevice !== null

    property int lastDeviceType: DeviceType.None
    property bool recentlyLostConnection: false
    onDeviceChanged: {
        if (root.device) root.lastDeviceType = root.device.type;
        root.recentlyLostConnection = !root.device;
    }

    Timer {
        running: !root.device && root.connectingDevice === null
        interval: 1000
        onTriggered: root.recentlyLostConnection = false
    }

    function getWifiBars(strength) {
        if (strength <= 0.0) return 0;
        if (strength <= 0.25) return 1;
        if (strength <= 0.5) return 2;
        if (strength <= 0.75) return 3;
        return 4;
    }
    readonly property int targetFrame: root.network ? getWifiBars(root.network.signalStrength) : 0

    readonly property bool animating: root.activelyConnecting || root.currentFrame !== root.targetFrame

    property int currentFrame: 0
    property int animDirection: 1
    Timer {
        running: root.animating
        interval: 150
        repeat: true
        onTriggered: {
            if (root.activelyConnecting) {
                if (root.currentFrame >= 4) root.animDirection = -1;
                else if (root.currentFrame <= 0) root.animDirection = 1;
                root.currentFrame = Math.max(0, Math.min(4, root.currentFrame + root.animDirection));
            } else {
                if (root.currentFrame < root.targetFrame) root.currentFrame += 1;
                else if (root.currentFrame > root.targetFrame) root.currentFrame -= 1;
                root.animDirection = 1;
            }
        }
    }

    readonly property bool showWifi: root.activelyConnecting || root.currentFrame > 0 || (root.recentlyLostConnection && root.lastDeviceType === DeviceType.Wifi) || (root.device && root.device.type === DeviceType.Wifi)

    text: {
        if (root.device && root.device.type === DeviceType.Wired)
            return "󰈀";
        if (root.showWifi)
            return Config.wifiIcon(root.currentFrame * 0.25, false);
        return "󰖪";
    }

    textColor: (root.device || root.showWifi) ? Config.foreground : Config.alert

    tooltipText: {
        if (root.activelyConnecting)
            return "Connecting...";
        if (!root.device)
            return "Disconnected";
        const name = root.network?.name ?? root.device.name;
        const label = name === root.device.name ? name : `${name} (${root.device.name})`;
        if (root.device.type === DeviceType.Wifi && root.network)
            return `${label} · ${Math.round(root.network.signalStrength * 100)}%`;
        return label;
    }

    dropdown: WifiMenu {
        active: root.dropdownOpen

        onCloseRequested: root.closeDropdown()
    }
}
