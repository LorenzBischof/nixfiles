import QtQuick

// Section label inside a dropdown. Indented to the same column as the rows,
// which carry their own side padding now that they span the panel.
BarText {
    leftPadding: Config.menuPadding
    color: Config.popupTextDim
    font.pointSize: Config.fontPointSize - 1
}
