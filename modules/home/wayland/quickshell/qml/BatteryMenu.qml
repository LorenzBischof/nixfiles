import QtQuick
import Quickshell.Services.UPower

// Contents of the battery dropdown: the numbers behind the bar's single glyph,
// and the one power decision worth making from here -- which profile the
// machine runs at.
Column {
    id: root

    // Handed down from the bar module rather than read again here, so which
    // UPower device counts as the battery, and how its state is classified,
    // is decided in one place.
    required property var device
    required property int percentage
    required property bool charging
    required property bool full

    // UPower reports the rate as a magnitude -- it takes the absolute value of
    // the kernel's power_now -- and quickshell passes the property through
    // untouched, so the sign its documentation promises is not there. The
    // state row above is what says which way the energy is going.
    readonly property real rate: Math.abs(root.device?.changeRate ?? 0)
    readonly property real remaining: (root.charging ? root.device?.timeToFull : root.device?.timeToEmpty) ?? 0

    readonly property string stateText: {
        switch (root.device?.state) {
        case UPowerDeviceState.Charging:
            return "Charging";
        case UPowerDeviceState.Discharging:
            return "Discharging";
        case UPowerDeviceState.FullyCharged:
            return "Fully charged";
        case UPowerDeviceState.Empty:
            return "Empty";
        // On mains, with the battery neither taking nor giving charge: what a
        // charge limit looks like once it is reached.
        case UPowerDeviceState.PendingCharge:
            return "Not charging";
        case UPowerDeviceState.PendingDischarge:
            return "Idle";
        default:
            return "Unknown";
        }
    }

    // The profiles power-profiles-daemon offers. Three silhouettes rather than
    // three positions of the same dial, which at this size were telling each
    // other apart by the angle of one needle. Performance is listed only where
    // ppd reports it, since it depends on the firmware and a row that silently
    // does nothing is worse than no row.
    readonly property var allProfiles: [
        {
            profile: PowerProfile.PowerSaver,
            label: "Power saver",
            icon: "󰌪"
        },
        {
            profile: PowerProfile.Balanced,
            label: "Balanced",
            icon: "󰗑"
        },
        {
            profile: PowerProfile.Performance,
            label: "Performance",
            icon: "󱓞"
        }
    ]
    readonly property var profiles: PowerProfiles.hasPerformanceProfile ? root.allProfiles : root.allProfiles.filter(entry => entry.profile !== PowerProfile.Performance)

    // A QML sequence rather than a JS array, and Repeater wants an array.
    readonly property var holds: Array.prototype.slice.call(PowerProfiles.holds)

    // Named off the full list, so a hold on a profile this machine does not
    // offer still reads as something rather than as a blank column.
    function profileLabel(profile: int): string {
        const match = root.allProfiles.find(entry => entry.profile === profile);
        return match ? match.label : "";
    }

    spacing: Config.menuSpacing

    MenuHeading {
        text: "Battery"
    }

    MenuRow {
        width: parent.width
        icon: Config.batteryIcon(root.percentage, root.charging, root.full)
        text: root.stateText
        detail: `${root.percentage}%`
        interactive: false
    }

    // UPower zeroes the estimate it is not making, and publishes neither for
    // the first minutes after a plug event while it re-fits the curve.
    MenuRow {
        width: parent.width
        visible: root.remaining > 0

        icon: "󰥔"
        text: root.charging ? "Until full" : "Time left"
        detail: Config.durationText(root.remaining)
        interactive: false
    }

    MenuRow {
        width: parent.width
        visible: root.rate > 0

        icon: "󱐋"
        text: root.charging ? "Charge rate" : "Power draw"
        detail: `${root.rate.toFixed(1)} W`
        interactive: false
    }

    // Full capacity against the capacity this pack was built with. Unlike
    // every other percentage here, UPower hands this one over as 0-100.
    MenuRow {
        width: parent.width
        visible: root.device?.healthSupported ?? false

        icon: "󱈏"
        text: "Health"
        detail: `${Math.round(root.device?.healthPercentage ?? 0)}%`
        interactive: false
    }

    MenuSeparator {
        width: parent.width
    }

    MenuHeading {
        text: "Power profile"
    }

    Repeater {
        model: root.profiles

        MenuRow {
            required property var modelData

            width: root.width
            icon: modelData.icon
            text: modelData.label
            checked: PowerProfiles.profile === modelData.profile
            detail: PowerProfiles.profile === modelData.profile ? "󰄬" : ""

            onClicked: PowerProfiles.profile = modelData.profile
        }
    }

    // An application can pin a profile for as long as it runs, which is the
    // other reason the machine may not be on the profile ticked above.
    Repeater {
        model: root.holds

        MenuRow {
            required property var modelData

            width: root.width
            icon: "󰐃"
            text: modelData.reason || modelData.applicationId
            detail: root.profileLabel(modelData.profile)
            interactive: false
        }
    }

    // Performance the hardware is refusing to deliver, whatever the profile
    // says: the laptop is too hot, or it has decided it is on a lap.
    MenuRow {
        width: parent.width
        visible: PowerProfiles.degradationReason !== PerformanceDegradationReason.None

        icon: PowerProfiles.degradationReason === PerformanceDegradationReason.HighTemperature ? "󰔏" : "󰀄"
        text: PowerProfiles.degradationReason === PerformanceDegradationReason.HighTemperature ? "Throttled: too hot" : "Throttled: on a lap"
        interactive: false
    }
}
