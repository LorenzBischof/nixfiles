import QtQuick
import QtQuick.Controls.Basic
import Quickshell.Networking

// One wifi network in the dropdown. The row alone is the whole story for a
// network that just works; the panel under it unfolds only when the network
// needs something -- a password to join, or a decision about a saved profile.
Column {
    id: root

    required property var network
    // Whether this row's panel is the one showing. The menu owns it so that
    // only one panel is open at a time.
    required property bool expanded

    signal expandRequested(bool expand)

    // The only secrets NetworkManager will take from us as a bare string.
    // Enterprise and WEP networks need a profile built elsewhere, so there is
    // nothing useful to prompt for.
    readonly property bool pskCapable: {
        switch (root.network.security) {
        case WifiSecurityType.WpaPsk:
        case WifiSecurityType.Wpa2Psk:
        case WifiSecurityType.Sae:
            return true;
        default:
            return false;
        }
    }

    readonly property bool secured: {
        switch (root.network.security) {
        case WifiSecurityType.Open:
        case WifiSecurityType.Owe:
        case WifiSecurityType.Unknown:
            return false;
        default:
            return true;
        }
    }

    // Set once an attempt has come back wanting secrets, so the panel prompts
    // instead of only offering to forget.
    property bool asking: false
    property string error: ""
    
    // Tracks if this row is the active target of a connect/disconnect operation
    // initiated by the user, so we don't show confusing spinners on networks
    // that are passively disconnecting in the background.
    property bool isTarget: false

    // Panel contents line up with the row's label rather than its icon, so the
    // whole thing reads as hanging off the network it belongs to.
    readonly property int indent: Config.menuPadding + Config.menuIconWidth + Config.menuSpacing

    function failureText(reason): string {
        switch (reason) {
        case ConnectionFailReason.NoSecrets:
            return "Wrong password";
        case ConnectionFailReason.WifiAuthTimeout:
            return "Authentication timed out";
        case ConnectionFailReason.WifiNetworkLost:
            return "Network went out of range";
        case ConnectionFailReason.WifiClientDisconnected:
            return "Disconnected";
        default:
            return "Could not connect";
        }
    }

    // Upstream recommends trying a plain connect first even for secured
    // networks: the backend may already hold the secret, and prompting for one
    // it does not need is pure friction. Only a network we know has no saved
    // profile is worth asking about up front.
    function attempt(): void {
        root.error = "";
        root.isTarget = true;
        if (root.network.known || !root.pskCapable) {
            root.network.connect();
            return;
        }
        root.asking = true;
        root.expandRequested(true);
    }

    function submit(): void {
        if (psk.text === "")
            return;
        root.error = "";
        root.isTarget = true;
        root.network.connectWithPsk(psk.text);
    }

    spacing: 0

    // A closed panel keeps nothing: a half-typed password must not survive the
    // row being collapsed and reopened.
    onExpandedChanged: {
        if (!root.expanded) {
            psk.text = "";
            root.asking = false;
            root.error = "";
        }
    }

    Connections {
        target: root.network

        function onStateChangingChanged() {
            if (!root.network.stateChanging)
                root.isTarget = false;
        }

        function onConnectionFailed(reason) {
            root.isTarget = false;
            root.asking = true;
            // NoSecrets on a network nothing has been typed into yet is just a
            // request for a password, not a wrong one.
            root.error = reason === ConnectionFailReason.NoSecrets && psk.text === "" ? "" : root.failureText(reason);
            psk.text = "";
            root.expandRequested(true);
        }

        function onConnectedChanged() {
            if (root.network.connected)
                root.expandRequested(false);
        }
    }

    MenuRow {
        width: parent.width

        icon: Config.wifiIcon(root.network.signalStrength, root.secured)
        text: root.network.name
        checked: root.network.connected
        spinning: root.isTarget || root.network.state === ConnectionState.Connecting
        detail: {
            return root.network.connected && !root.network.stateChanging ? "󰄬" : "";
        }

        // Left click does the obvious thing; right click opens the panel on any
        // network, which is the only way to forget one that is not connected.
        onClicked: {
            if (root.network.stateChanging)
                return;
            if (root.network.connected)
                root.expandRequested(!root.expanded);
            else
                root.attempt();
        }

        onRightClicked: root.expandRequested(!root.expanded)
    }

    Column {
        width: parent.width
        visible: root.expanded
        spacing: 0

        BarText {
            x: root.indent
            width: parent.width - root.indent - Config.menuPadding
            topPadding: Config.menuSpacing
            bottomPadding: Config.menuSpacing
            text: root.error
            color: Config.alert
            font.pointSize: Config.fontPointSize - 1
            wrapMode: Text.Wrap
            visible: root.error !== ""
        }

        BarText {
            x: root.indent
            width: parent.width - root.indent - Config.menuPadding
            topPadding: Config.menuSpacing
            bottomPadding: Config.menuSpacing
            text: "Needs a profile from NetworkManager."
            color: Config.popupTextDim
            font.pointSize: Config.fontPointSize - 1
            wrapMode: Text.Wrap
            visible: root.asking && !root.pskCapable
        }

        Item {
            id: pskRow

            width: parent.width
            implicitHeight: Config.menuRowHeight + Config.menuSpacing
            visible: root.asking && root.pskCapable && !root.network.connected

            // The panel opens because a password is wanted, so the caret starts
            // where it is wanted rather than making the user click for it.
            onVisibleChanged: {
                if (pskRow.visible)
                    psk.forceActiveFocus();
            }

            TextField {
                id: psk

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: root.indent
                anchors.rightMargin: Config.menuPadding
                anchors.verticalCenter: parent.verticalCenter

                echoMode: TextInput.Password
                placeholderText: "Password"
                placeholderTextColor: Config.subtle
                color: Config.popupText
                font.family: Config.fontFamily
                font.pointSize: Config.fontPointSize
                renderType: Text.NativeRendering
                padding: Config.menuSpacing
                selectByMouse: true

                onAccepted: root.submit()

                // Square and recessed, like every other surface here: the panel
                // is the raised thing, a field cut into it is not.
                background: Rectangle {
                    color: Config.background
                    border.width: Config.popupOutline
                    border.color: psk.activeFocus ? Config.accent : Config.overlay
                }
            }
        }

        MenuRow {
            width: parent.width
            icon: "󰌘"
            text: "Connect"
            visible: root.asking && root.pskCapable && !root.network.connected

            onClicked: root.submit()
        }

        MenuRow {
            width: parent.width
            icon: "󰌙"
            text: "Disconnect"
            visible: root.network.connected

            onClicked: {
                root.isTarget = true;
                root.network.disconnect();
                root.expandRequested(false);
            }
        }

        MenuRow {
            width: parent.width
            icon: "󰆴"
            text: "Forget network"
            visible: root.network.known

            onClicked: {
                root.network.forget();
                root.expandRequested(false);
            }
        }
    }
}
