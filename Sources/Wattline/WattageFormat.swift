import Foundation

enum WattageFormat {
    static func menuDraw(_ watts: Double?, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let watts, watts.isFinite, watts > 0 else { return nil }
        return power(watts, digits: 0, threshold: 1, locale: locale)
    }

    static func detail(_ watts: Double?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let watts, watts.isFinite, watts >= 0 else { return "—" }
        return power(watts, digits: 1, threshold: 0.1, locale: locale)
    }

    static func processPower(_ watts: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard watts.isFinite, watts >= 0 else { return "—" }
        return power(watts, digits: watts < 1 ? 2 : 1, threshold: 0.01, locale: locale)
    }

    static func cpuUsage(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        let format = FloatingPointFormatStyle<Double>.Percent.percent
            .precision(.fractionLength(value < 1 ? 1 : 0)).locale(locale)
        if value > 0 && value < 0.1 { return "<" + 0.001.formatted(format) }
        // macOS reports percent of one core and can exceed 100%.
        return (value / 100).formatted(format)
    }

    private static func power(_ value: Double, digits: Int, threshold: Double, locale: Locale) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(digits)).locale(locale)
        if value > 0 && value < threshold { return "<" + threshold.formatted(format) + " W" }
        return value.formatted(format) + " W"
    }
}
