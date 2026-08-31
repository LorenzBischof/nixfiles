import QtQuick
import Quickshell.Services.UPower

BarModule {
    id: root

    readonly property var battery: UPower.displayDevice
    readonly property bool present: battery !== null && battery.isLaptopBattery && battery.isPresent
    readonly property int percentage: present ? Math.round(battery.percentage * 100) : 0
    readonly property bool charging: present && (battery.state === UPowerDeviceState.Charging || battery.state === UPowerDeviceState.PendingCharge)
    readonly property bool full: present && battery.state === UPowerDeviceState.FullyCharged
    readonly property bool critical: present && !charging && percentage <= 10

    visible: root.present

    text: {
        if (root.full)
            return "󱈑";
        if (root.charging)
            return "󰂄";
        const icons = Config.batteryIcons;
        return icons[Math.min(icons.length - 1, Math.floor(root.percentage / 10))];
    }

    textColor: root.charging ? Config.ok : root.critical ? Config.alert : Config.foreground

    tooltipText: {
        if (!root.present)
            return "";
        const seconds = root.charging ? root.battery.timeToFull : root.battery.timeToEmpty;
        if (seconds <= 0)
            return `${root.percentage}%`;
        const hours = Math.floor(seconds / 3600);
        const minutes = Math.floor(seconds % 3600 / 60);
        return `${root.percentage}%, ${hours} h ${minutes} min to ${root.charging ? "full" : "empty"}`;
    }

    // A critical battery blinks until it is plugged in.
    SequentialAnimation on opacity {
        running: root.critical
        loops: Animation.Infinite

        NumberAnimation {
            to: 0
            duration: 1000
        }
        NumberAnimation {
            to: 1
            duration: 1000
        }

        onRunningChanged: if (!running)
            root.opacity = 1
    }
}
