pragma Singleton

import QtQuick
import Quickshell

// Which bar module has its panel open, if any.
//
// One panel is open at a time, and each bar draws it in a single window (see
// Dropdown.qml), so naming the module here is the whole of the state: the
// panel follows whoever is named, and handing it from one module to the next
// is what closes the previous one. A window each would have meant the old one
// unmapping before the new one had painted, blinking the desktop through
// between two panels that otherwise share a background.
//
// Nothing enforces one-at-a-time from the outside: bar clicks pass through the
// open panel's input region (see Dropdown.qml), so a click on another module
// reaches the bar rather than the panel.
Singleton {
    id: root

    property Item owner: null

    function close(): void {
        root.owner = null;
    }

    function toggle(module: Item): void {
        root.owner = root.owner === module ? null : module;
    }
}
