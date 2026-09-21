import QtQuick
import Quickshell
import Quickshell.Networking

// Contents of the network dropdown: a wifi switch, every network in range with
// the strongest first, and the wired link when there is one.
Column {
    id: root

    signal closeRequested

    // Whether the dropdown is on screen. Scanning keeps the radio busy, so it
    // is confined to the moments the list is actually being looked at.
    required property bool active

    readonly property bool hasBackend: Networking.backend !== NetworkBackendType.None
    readonly property var wifiDevice: Networking.devices.values.find(dev => dev.type === DeviceType.Wifi) ?? null
    readonly property var wiredDevice: Networking.devices.values.find(dev => dev.type === DeviceType.Wired) ?? null

    // The order the rows are drawn in, by name. Sorting live is what made the
    // list feel loose: joining a network re-rates it -- the backend swaps the
    // scan's estimate for the link's own signal, and often hands back a fresh
    // object for the SSID as it does -- so the network just clicked would walk
    // off to the bottom of the list at the moment it succeeded. The order is
    // therefore decided once per opening, strongest first with whatever is
    // connected on top, and then held: a network a later scan finds is appended
    // and one that goes out of range leaves, and nothing else moves for as long
    // as the dropdown is up. By name rather than by object, so a row keeps its
    // place across a swap.
    property var order: []

    function reorder(): void {
        const values = root.wifiDevice ? root.wifiDevice.networks.values : [];
        const ranked = values.slice().sort((a, b) => {
            if (a.connected !== b.connected)
                return a.connected ? -1 : 1;
            // By the bar count the row actually draws rather than the raw
            // signal: a network only outranks another when its icon says so.
            return Config.wifiBars(b.signalStrength) - Config.wifiBars(a.signalStrength) || a.name.localeCompare(b.name);
        }).map(n => n.name);
        const kept = root.order.filter(name => ranked.includes(name));
        root.order = kept.concat(ranked.filter((name, i) => !kept.includes(name) && ranked.indexOf(name) === i));
    }

    readonly property var networks: {
        if (!root.wifiDevice)
            return [];
        const order = root.order;
        // A network reorder() has not placed yet sorts to the end, which is
        // where it is about to be placed anyway.
        const place = name => {
            const i = order.indexOf(name);
            return i < 0 ? order.length : i;
        };
        return root.wifiDevice.networks.values.slice().sort((a, b) => place(a.name) - place(b.name));
    }

    // Only one network's panel is open at a time.
    property var expandedNetwork: null

    spacing: Config.menuSpacing

    // Without the scanner the device only reports the networks it is connected
    // to or has a profile for, so this is what makes the list a list.
    Binding {
        target: root.wifiDevice
        property: "scannerEnabled"
        value: root.active
    }

    onActiveChanged: {
        if (root.active) {
            // A fresh opening is the one moment a reshuffle is free, so it is
            // the only one that gets to sort what is already listed.
            root.order = [];
            root.reorder();
        } else {
            root.expandedNetwork = null;
        }
    }

    // Membership only: a scan republishing signal strengths leaves the list
    // alone, and the rows read the new strength for themselves.
    Connections {
        target: root.wifiDevice ? root.wifiDevice.networks : null

        function onValuesChanged() {
            root.reorder();
        }
    }

    BarText {
        leftPadding: Config.menuPadding
        rightPadding: Config.menuPadding
        width: parent.width
        text: "No network backend"
        color: Config.popupTextDim
        wrapMode: Text.Wrap
        visible: !root.hasBackend
    }

    MenuRow {
        width: parent.width
        visible: root.hasBackend && root.wifiDevice !== null

        icon: Networking.wifiEnabled ? "󰤨" : "󰤮"
        text: "Wi-Fi"
        checked: Networking.wifiEnabled
        // An rfkill hardware block cannot be undone from here, so the row says
        // so rather than offering a switch that would do nothing.
        detail: {
            if (!Networking.wifiHardwareEnabled) return "blocked";
            if (Networking.connectivity === NetworkConnectivity.Portal) return "󰀪 captive portal";
            return Networking.wifiEnabled ? "on" : "off";
        }
        interactive: Networking.wifiHardwareEnabled

        onClicked: Networking.wifiEnabled = !Networking.wifiEnabled
    }

    MenuSeparator {
        width: parent.width
        visible: root.hasBackend && Networking.wifiEnabled && root.wifiDevice !== null
    }

    // Wrapped in a ScriptModel rather than handed the array directly: a plain
    // javascript model makes Repeater destroy and rebuild every delegate each
    // time the expression changes, and this one re-runs on every network's
    // signal strength, which NetworkManager republishes per access point all
    // through a scan. Thirty networks in range then meant thirty rows -- some
    // hundreds of items -- torn down and rebuilt many times a second for as
    // long as the panel stayed open, which is what eventually wedged it.
    // ScriptModel diffs the list and emits row moves instead.
    Repeater {
        // A scan can insert several delegates before Column's deferred layout
        // runs. Flush it on the next event-loop turn so the popup sees the new
        // content height rather than retaining the previous row geometry.
        onCountChanged: Qt.callLater(() => root.forceLayout())

        model: ScriptModel {
            values: Networking.wifiEnabled ? root.networks : []
        }

        WifiRow {
            required property var modelData

            width: root.width
            network: modelData
            expanded: root.expandedNetwork === modelData

            onExpandRequested: expand => root.expandedNetwork = expand ? modelData : null
        }
    }

    // The first scan starts when the popup opens, so give the otherwise empty
    // list a full-height status row. A rotating trail is easier to notice than
    // the old bare label, especially while the popup is still growing.
    Item {
        id: scanningRow

        width: parent.width
        implicitHeight: Config.menuRowHeight
        visible: root.active && Networking.wifiEnabled && root.wifiDevice !== null && root.networks.every(n => n.connected)

        BarText {
            id: spinner

            anchors.left: parent.left
            anchors.leftMargin: Config.menuPadding
            anchors.verticalCenter: parent.verticalCenter
            width: Config.menuIconWidth
            height: Config.menuIconWidth
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "󰑐"
            color: Config.popupTextDim

            RotationAnimator {
                target: spinner
                from: 0
                to: 360
                duration: 1500
                loops: Animation.Infinite
                running: scanningRow.visible

                onRunningChanged: if (!running)
                    spinner.rotation = 0
            }
        }

        BarText {
            anchors.left: spinner.right
            anchors.leftMargin: Config.menuSpacing
            anchors.right: parent.right
            anchors.rightMargin: Config.menuPadding
            anchors.verticalCenter: parent.verticalCenter
            text: "Scanning…"
            color: Config.popupTextDim
        }
    }

    MenuSeparator {
        width: parent.width
        visible: root.wiredDevice !== null
    }

    MenuHeading {
        text: "Wired"
        visible: root.wiredDevice !== null
    }

    // Reporting only: the wired link is usually the one carrying this session,
    // and a stray click is no way to drop it.
    MenuRow {
        width: parent.width
        visible: root.wiredDevice !== null

        icon: root.wiredDevice?.connected ? "󰈀" : "󰈂"
        text: root.wiredDevice?.name ?? ""
        checked: root.wiredDevice?.connected ?? false
        interactive: false
        detail: {
            if (!root.wiredDevice)
                return "";
            if (!root.wiredDevice.hasLink)
                return "no link";
            const mbps = root.wiredDevice.linkSpeed;
            return mbps >= 1000 ? `${mbps / 1000} Gb/s` : `${mbps} Mb/s`;
        }
    }
}
