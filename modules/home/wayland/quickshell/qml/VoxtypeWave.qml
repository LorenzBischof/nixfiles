pragma ComponentBehavior: Bound

import QtQuick

// What voxtype is hearing, for as long as it is listening: the last second or
// so of audio as a strip of level bars, faded down.
//
// It sits in the bar, in the empty stretch left of the status icons, and is
// placed by anchor rather than laid out with them -- so it costs the modules
// no width and none of them move when a recording starts. That was the whole
// problem with drawing it inside the voxtype module itself: a strip that comes
// and goes there has to take its width from the bar, and every icon to its
// left slid along each time.
//
// No chrome and no icon of its own: this is confirmation that the microphone
// is live, caught out of the corner of the eye while reading something else.
// The module's icon a few positions along is where the state is actually read.
Item {
    id: root

    implicitWidth: Config.waveformWidth
    implicitHeight: Config.waveformHeight

    // Down only once the last column has scrolled off, so there is never a
    // frame where something visible disappears.
    visible: VoxtypeState.active
    opacity: Config.waveformOpacity

    Row {
        anchors.fill: parent
        spacing: Config.waveformBarSpacing

        Repeater {
            model: VoxtypeState.levels

            // A full-height cell holding the bar, rather than the bar itself:
            // a column with no audio in it draws nothing, and Qt's positioners
            // drop a zero-height child out of the layout altogether -- which
            // packs the remaining bars against the left edge and turns the
            // scroll into a grow-from-the-left on the way in and a
            // shrink-from-the-right on the way out. The cell keeps every
            // column's place whether or not anything is drawn in it.
            Item {
                id: cell

                required property var modelData

                implicitWidth: Config.waveformBarWidth
                implicitHeight: Config.waveformHeight

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    // Square root rather than the raw amplitude: speech peaks
                    // sit around a fifth of full scale, so drawn linearly the
                    // strip would be a flat line with the occasional spike. No
                    // floor under it: a column that has never held audio draws
                    // nothing at all, rather than putting a full-width line
                    // across the strip before a word has been said.
                    height: Math.round(Math.sqrt(cell.modelData) * Config.waveformHeight)
                    // The listening colour, held for the whole of the
                    // scroll-out rather than taken from the state, which has
                    // already moved on to transcribing by then.
                    color: Config.alert
                }
            }
        }
    }
}
