import QtQuick
import Quickshell
import Quickshell.Wayland

// The function row, drawn at its real size along the bottom edge so each key
// sits directly above the physical one. For keycaps with nothing printed on
// them: glance down and the legend lines up with what your fingers are already
// on. Just the keys themselves -- every cap at the size and shape of the one it
// stands for, wide and flat rather than square, with the two ends wider -- and
// no labels or backdrop around them, so it reads as the keyboard rather than as
// a panel about the keyboard.
//
// Put up by a tap of Right-Ctrl standing in for Fn; see FnOverlayState.qml for
// why Fn itself cannot do it.
//
// The glyphs are what the EC's hotkey_F1_F12, hotkey_special_key and
// functional_hotkey actually do with each key, rather than what the keycaps in
// the shop have printed on them: F12 is the Framework key, which the EC sends
// as a bare Media Select scancode.
//
// They show what each key does pressed on its own, which is the layout with Fn
// Lock off. Fn Lock swaps the row over to F1-F12, and the EC keeps that state
// entirely to itself -- no host command, HID report or sysfs attribute reports
// it -- so the legend cannot follow it. Off is what the sway bindings for
// XF86AudioMute and friends assume too.
PanelWindow {
    id: root

    // The built-in panel, and only that one: this is a picture of the built-in
    // keyboard at 1:1, so it means nothing anywhere else.
    readonly property string screenName: "eDP-1"

    // Esc and Delete are wider than an F key and sit outside F1-F12, so they
    // are placed from the ends of the row inwards rather than on the F pitch.
    readonly property var keys: [
        {
            glyph: "Esc",
            isText: true
        },
        {
            glyph: "󰝟",
            isText: false
        },
        {
            glyph: "󰖀",
            isText: false
        },
        {
            glyph: "󰕾",
            isText: false
        },
        {
            glyph: "󰒮",
            isText: false
        },
        {
            glyph: "󰐎",
            isText: false
        },
        {
            glyph: "󰒭",
            isText: false
        },
        {
            glyph: "󰃞",
            isText: false
        },
        {
            glyph: "󰃠",
            isText: false
        },
        {
            glyph: "󰍹",
            isText: false
        },
        {
            glyph: "󰀝",
            isText: false
        },
        {
            glyph: "󰹑",
            isText: false
        },
        {
            glyph: "󰀻",
            isText: false
        },
        {
            glyph: "Del",
            isText: true
        }
    ]

    // Resolved into a property of its own rather than read back off `screen`,
    // which the window reassigns as it maps: a `visible` binding that looks at
    // `screen` feeds itself and Qt drops it as a binding loop, leaving the
    // legend permanently invisible.
    //
    // Indexed rather than `find`: Quickshell.screens is a QML list property,
    // which only promises length and indexing. Re-resolved whenever the screen
    // list changes, so closing the lid takes the legend with it.
    readonly property var targetScreen: {
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; i++) {
            if (screens[i].name === root.screenName)
                return screens[i];
        }
        return null;
    }

    // Millimetres to logical pixels, measured off the panel rather than
    // hardcoded, because the same panel runs at two scales: kanshi gives eDP-1
    // scale 2 in both docked profiles and leaves the undocked one at sway's
    // default of 1, which doubles the logical width. Taking it from the screen
    // keeps a key where it is in both.
    readonly property real pxPerMm: root.targetScreen ? root.targetScreen.width / Config.builtinPanelWidthMm : 0

    // The gap from one F key's centre to the next. F1's left edge and F12's
    // right edge are eleven pitches plus one cap apart.
    readonly property real pitchMm: (Config.fnKeySpanMm - Config.fnKeyWidthMm) / 11

    // Where each key's centre falls, in millimetres from the centre of the
    // machine -- which is also the centre of the display, both being centred on
    // the same chassis.
    //
    // F1-F12 are symmetric about that centre, so index 1 lands at -5.5 pitches
    // and index 12 at +5.5. Esc and Delete sit flush with the ends of the row,
    // which is what leaves exactly one key gap between them and their
    // neighbour: the width below is the overhang with that gap already taken
    // off. Centring them in the overhang instead would swallow half the gap at
    // each end and pull both keys 2 mm inwards.
    function keyOffsetMm(index: int): real {
        if (root.isEndKey(index))
            return (index === 0 ? -1 : 1) * (Config.fnRowWidthMm - root.keyWidthMm(index)) / 2;
        return (index - 6.5) * root.pitchMm;
    }

    function isEndKey(index: int): bool {
        return index === 0 || index === root.keys.length - 1;
    }

    // Esc and Delete are wider than an F key, and by exactly as much as the row
    // overhangs F1-F12 once the gap to the neighbouring F key is taken off. So
    // their width falls out of the same four measurements rather than needing
    // one of its own.
    function keyWidthMm(index: int): real {
        if (!root.isEndKey(index))
            return Config.fnKeyWidthMm;

        const overhang = (Config.fnRowWidthMm - Config.fnKeySpanMm) / 2;
        return overhang - (root.pitchMm - Config.fnKeyWidthMm);
    }

    screen: root.targetScreen
    color: "transparent"
    visible: FnOverlayState.shown && root.targetScreen !== null
    implicitHeight: (Config.fnKeyHeightMm + Config.fnBottomMarginMm * 2) * root.pxPerMm

    // Over the windows rather than among them, and taking no space from them:
    // the legend comes and goes under a held key, and reflowing every tiled
    // window twice per lookup would make it unusable.
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // The panel spans the screen so the glyphs can be placed against its
    // centre, which would otherwise put a transparent input-catching strip
    // across the bottom of every window. An empty mask makes the whole surface
    // pointer-through.
    mask: Region {}

    anchors {
        bottom: true
        left: true
        right: true
    }

    Repeater {
        model: root.keys

        // Placed by centre rather than laid out in a row: the two ends are
        // wider and do not sit on the F pitch, so there is no single spacing to
        // hand a Row. Each is drawn at the size of the key it stands for --
        // wide and flat, not square -- so the row reads as the keyboard it is
        // sitting above. No backdrop behind them: the keys are the overlay.
        Rectangle {
            id: key

            required property int index
            required property var modelData

            x: root.width / 2 + root.keyOffsetMm(key.index) * root.pxPerMm - width / 2
            anchors.verticalCenter: parent.verticalCenter
            width: root.keyWidthMm(key.index) * root.pxPerMm
            height: Config.fnKeyHeightMm * root.pxPerMm
            radius: Config.fnKeyRadiusMm * root.pxPerMm
            color: Config.overlay
            border.width: Config.popupOutline
            border.color: Config.subtle

            // Sized in millimetres like the key it sits on, so a glyph keeps
            // its place on the cap at either panel scale. That rules out
            // BarText, whose point size follows the theme rather than the
            // keyboard.
            Text {
                anchors.centerIn: parent
                font.family: Config.fontFamily
                font.pixelSize: (key.modelData.isText ? Config.fnCapTextMm : Config.fnIconMm) * root.pxPerMm
                renderType: Text.NativeRendering
                color: Config.popupTextStrong
                text: key.modelData.glyph
            }
        }
    }
}
