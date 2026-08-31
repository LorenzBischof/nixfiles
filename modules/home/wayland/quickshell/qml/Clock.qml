import Quickshell

BarModule {
    text: Qt.formatDateTime(clock.date, "HH:mm")
    tooltipText: Qt.formatDateTime(clock.date, "yyyy-MM-dd dddd")

    SystemClock {
        id: clock

        precision: SystemClock.Minutes
    }
}
