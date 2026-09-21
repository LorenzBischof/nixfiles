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
    // Whether a password typed here is in flight. The panel is gone by the time
    // the answer comes back, so the field can no longer say whether a NoSecrets
    // failure is a wrong password or a first request for one.
    property bool triedSecret: false

    // Tracks if this row is the active target of a connect/disconnect operation
    // initiated by the user, so we don't show confusing spinners on networks
    // that are passively disconnecting in the background.
    property bool isTarget: false

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
        root.triedSecret = false;
        root.isTarget = true;
        if (root.network.known || !root.pskCapable) {
            root.network.connect();
            return;
        }
        root.asking = true;
        root.expandRequested(true);
    }

    // Enter is the end of the prompt. The row's own spinner carries the attempt
    // from here, so the panel closes on submit rather than sitting open with a
    // spent field in it -- and, once the profile exists, a "Forget network" row
    // nobody asked for. A failure brings it back with the reason.
    function submit(): void {
        const secret = psk.text;
        if (secret === "")
            return;
        root.error = "";
        root.isTarget = true;
        root.expandRequested(false);
        // After the collapse, which clears the panel and this flag with it.
        root.triedSecret = true;
        root.network.connectWithPsk(secret);
    }

    spacing: 0

    // A closed panel keeps nothing: a half-typed password must not survive the
    // row being collapsed and reopened.
    onExpandedChanged: {
        if (!root.expanded) {
            psk.text = "";
            root.asking = false;
            root.error = "";
            root.triedSecret = false;
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
            // NoSecrets before a password has been sent from here is a request
            // for one, not a rejection of one.
            root.error = reason === ConnectionFailReason.NoSecrets && !root.triedSecret ? "" : root.failureText(reason);
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

    MenuPanel {
        width: parent.width
        visible: root.expanded

        BarText {
            leftPadding: Config.menuPadding
            rightPadding: Config.menuPadding
            width: parent.width
            topPadding: Config.menuSpacing
            bottomPadding: Config.menuSpacing
            text: root.error
            color: Config.alert
            font.pointSize: Config.fontPointSize - 1
            wrapMode: Text.Wrap
            visible: root.error !== ""
        }

        BarText {
            leftPadding: Config.menuPadding
            rightPadding: Config.menuPadding
            width: parent.width
            topPadding: Config.menuSpacing
            bottomPadding: Config.menuSpacing
            text: "Needs a profile from NetworkManager."
            color: Config.popupTextDim
            font.pointSize: Config.fontPointSize - 1
            wrapMode: Text.Wrap
            visible: root.asking && !root.pskCapable
        }

        // The field carries the whole prompt, so it sits in a band of its own
        // padding rather than being centred in a row's worth of height, where
        // it came out welded to whatever is above it.
        Item {
            id: pskRow

            width: parent.width
            implicitHeight: psk.implicitHeight + Config.menuSpacing * 2
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
                anchors.leftMargin: Config.menuPadding
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
                rightPadding: Config.menuSpacing * 2 + submitHint.width
                selectByMouse: true

                onAccepted: root.submit()

                // Square, and carried by its border rather than by a ground of
                // its own: the group it sits in is already cut into the panel,
                // so a second step down would have nothing to step down from.
                background: Rectangle {
                    color: Config.background
                    border.width: Config.popupOutline
                    border.color: psk.activeFocus ? Config.accent : Config.overlay
                }

                // Submitting is Enter, so the return glyph inside the field
                // both says so and takes a click for the times it is not. A
                // full row for a button the caret is already aimed at is a
                // line the panel does not have to spend.
                BarText {
                    id: submitHint

                    anchors.right: parent.right
                    anchors.rightMargin: Config.menuSpacing
                    anchors.verticalCenter: parent.verticalCenter
                    width: Config.menuIconWidth
                    horizontalAlignment: Text.AlignHCenter
                    text: "󰌑"
                    color: psk.text === "" ? Config.subtle : (hintMouse.containsMouse ? Config.popupTextStrong : Config.accent)

                    MouseArea {
                        id: hintMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        onClicked: root.submit()
                    }
                }
            }
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
