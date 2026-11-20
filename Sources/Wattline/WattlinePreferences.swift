import Foundation

enum WattlinePreferences {
    static let appearanceKey = "wattlineAppearance"
    static let refreshKey = "wattlineMonitorRefreshSeconds"
    static let automaticStorageKey = "wattlineAutomaticStorageScan"
    static let healthAlertsKey = "wattlineHealthAlerts"
    static let historyRangeKey = "monitorHistoryRange"

    static let refreshIntervals = [2, 5, 10]
    static let historyRanges = [
        (seconds: 60, short: "1m", full: "1 minute"),
        (seconds: 300, short: "5m", full: "5 minutes"),
        (seconds: 3_600, short: "1h", full: "1 hour"),
        (seconds: 21_600, short: "6h", full: "6 hours"),
        (seconds: 86_400, short: "24h", full: "24 hours")
    ]

    static func historyRange(_ value: Int) -> Int {
        historyRanges.contains { $0.seconds == value } ? value : 3_600
    }

    static func refreshInterval(_ value: Int) -> Int {
        refreshIntervals.contains(value) ? value : 2
    }
}
