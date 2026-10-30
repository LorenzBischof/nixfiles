pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland

// The session lock, over ext-session-lock-v1. If this shell dies while locked,
// sway keeps the session locked rather than revealing it, so a crash fails
// closed. The one thing that opens it is a PAM success in `onCompleted` below:
// there is deliberately no unlock over IPC, since anything running as this user
// can reach that socket.
Scope {
    id: root

    property bool failed: false
    // Held between Enter and PAM asking for it, then dropped.
    property string password: ""

    // A rebuild restarts quickshell.service, and the hourly auto-upgrade does
    // that while the session sits locked. Sway keeps it locked with nothing left
    // to unlock it, so the lock state outlives the process here and a restarted
    // shell takes the lock straight back. XDG_RUNTIME_DIR is a tmpfs, so a
    // reboot clears it.
    FileView {
        id: marker

        path: Quickshell.env("XDG_RUNTIME_DIR") + "/quickshell-locked"
        blockLoading: true
        printErrors: false
    }

    Component.onCompleted: {
        if (marker.text().trim() === "1")
            root.lock();
    }

    function lock(): void {
        root.failed = false;
        marker.setText("1");
        sessionLock.locked = true;
    }

    function submit(text: string): void {
        if (text === "" || pam.active)
            return;
        root.failed = false;
        root.password = text;
        pam.start();
    }

    IpcHandler {
        target: "lock"

        function lock(): void {
            root.lock();
        }
    }

    PamContext {
        id: pam

        config: "quickshell"

        onPamMessage: {
            if (responseRequired) {
                respond(root.password);
                root.password = "";
            }
        }

        onCompleted: result => {
            root.password = "";
            if (result === PamResult.Success) {
                marker.setText("");
                sessionLock.locked = false;
            } else {
                root.failed = true;
            }
        }

        onError: {
            root.password = "";
            root.failed = true;
        }
    }

    WlSessionLock {
        id: sessionLock

        // One per output. Only the focused one gets keys, so each keeps its own
        // field and hands the text over on Enter.
        WlSessionLockSurface {
            color: "black"

            Column {
                anchors.centerIn: parent
                spacing: Config.menuSpacing

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(ClockState.date, "HH:mm")
                    color: Config.popupTextStrong
                    font.family: Config.fontFamily
                    font.pointSize: Config.fontPointSize * 5
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDateTime(ClockState.date, "dddd, d MMMM")
                    color: Config.popupTextDim
                    font.family: Config.fontFamily
                    font.pointSize: Config.fontPointSize
                }

                Item {
                    width: 1
                    height: Config.menuSpacing * 4
                }

                Rectangle {
                    id: field

                    readonly property int dotSize: Config.fontPointSize

                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.round(Config.menuWidth * 1.5)
                    height: Config.menuRowHeight * 2
                    clip: true
                    color: Config.surface
                    border.width: Config.popupBorder
                    border.color: root.failed ? Config.alert : pam.active ? Config.accent : Config.overlay
                    transform: Translate {
                        id: shakeOffset
                    }

                    // Takes the keys and nothing else: the dots below stand in
                    // for it, so neither its text nor its cursor is drawn.
                    TextInput {
                        id: input

                        anchors.fill: parent
                        opacity: 0
                        focus: true
                        readOnly: pam.active
                        echoMode: TextInput.Password

                        onTextEdited: root.failed = false
                        onAccepted: {
                            root.submit(text);
                            text = "";
                        }
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: field.dotSize / 2

                        Repeater {
                            model: input.length

                            Rectangle {
                                width: field.dotSize
                                height: field.dotSize
                                radius: width / 2
                                color: Config.foreground
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: input.text === ""
                        text: root.failed ? "Wrong password" : pam.active ? "Checking…" : "Password"
                        color: root.failed ? Config.alert : Config.subtle
                        font.family: Config.fontFamily
                        font.pointSize: Config.fontPointSize
                    }
                }
            }

            SequentialAnimation {
                id: shake

                NumberAnimation { target: shakeOffset; property: "x"; to: 10; duration: 40 }
                NumberAnimation { target: shakeOffset; property: "x"; to: -10; duration: 80 }
                NumberAnimation { target: shakeOffset; property: "x"; to: 6; duration: 70 }
                NumberAnimation { target: shakeOffset; property: "x"; to: 0; duration: 50 }
            }

            Connections {
                target: root

                function onFailedChanged(): void {
                    if (root.failed)
                        shake.restart();
                }
            }
        }
    }
}
