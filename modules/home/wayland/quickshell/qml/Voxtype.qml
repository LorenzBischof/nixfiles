import QtQuick

// The daemon's state as one icon, with a click to start or stop a recording.
// What it is hearing is drawn by VoxtypeWave; everything either of them reads
// lives in VoxtypeState.
BarModule {
    id: root

    buttons: Qt.LeftButton

    text: VoxtypeState.statusText
    tooltipText: VoxtypeState.tooltip
    textColor: VoxtypeState.statusColor
    visible: root.text !== ""

    onClicked: VoxtypeState.toggle()
}
