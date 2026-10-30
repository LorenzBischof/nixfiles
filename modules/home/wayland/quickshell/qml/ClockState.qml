pragma Singleton

import Quickshell
import Quickshell.Io

// The one clock the bar and the lock screen both read, so a single IPC call
// can set both right.
//
// SystemClock waits for the next minute on a QTimer, which runs on the
// monotonic clock and so stands still through suspend: on wake it still has
// whatever was left of the minute to go, and shows the time from before the
// suspend for up to another minute. swayidle's after-resume calls refresh()
// (see ../../default.nix), and toggling `enabled` makes SystemClock re-read
// the time and reschedule from now.
//
// Drop this once SystemClock waits on the wall clock itself:
// https://github.com/quickshell-mirror/quickshell/issues/1212
Singleton {
    readonly property alias date: clock.date

    SystemClock {
        id: clock

        precision: SystemClock.Minutes
    }

    IpcHandler {
        target: "clock"

        function refresh(): void {
            clock.enabled = false;
            clock.enabled = true;
        }
    }
}
