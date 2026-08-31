import QtQuick

// Every label in the bar, in the one font and rendering mode.
Text {
    color: Config.foreground
    font.family: Config.fontFamily
    font.pointSize: Config.fontPointSize
    renderType: Text.NativeRendering
}
