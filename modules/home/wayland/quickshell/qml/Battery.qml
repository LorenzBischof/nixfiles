pragma ComponentBehavior: Bound

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

    text: Config.batteryIcon(root.percentage, root.charging, root.full)

    textColor: root.charging ? Config.ok : root.critical ? Config.alert : Config.foreground

    tooltipText: {
        if (!root.present)
            return "";
        const seconds = root.charging ? root.battery.timeToFull : root.battery.timeToEmpty;
        if (seconds <= 0)
            return `${root.percentage}%`;
        return `${root.percentage}%, ${Config.durationText(seconds)} to ${root.charging ? "full" : "empty"}`;
    }

    dropdown: BatteryMenu {
        device: root.battery
        percentage: root.percentage
        charging: root.charging
        full: root.full
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
