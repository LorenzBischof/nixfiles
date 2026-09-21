import QtQuick

// Every label in the bar, in the one font and rendering mode.
Text {
    // Never markup, however the string arrived. Text defaults to AutoText,
    // which sniffs for tags and quietly switches to StyledText -- and several
    // labels here carry strings this machine did not write: an SSID off the
    // air, a bluetooth device name, a notification's app name. StyledText
    // renders <b> as bold, and resolves <img src=...> by opening and decoding
    // whatever it names, so an access point calling itself
    // <img src='file:///...'> is enough to make the bar read a file of its
    // choosing. Pinned here rather than at each label, so a label added later
    // cannot forget it.
    textFormat: Text.PlainText

    color: Config.foreground
    font.family: Config.fontFamily
    font.pointSize: Config.fontPointSize
    renderType: Text.NativeRendering
}
