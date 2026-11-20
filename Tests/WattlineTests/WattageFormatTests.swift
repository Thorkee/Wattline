import Foundation
import XCTest
@testable import Wattline

final class WattageFormatTests: XCTestCase {
    func testMenuDrawNeverRoundsSubwattOrUnavailableReadingsToZero() {
        let locale = Locale(identifier: "en_US")
        XCTAssertNil(WattageFormat.menuDraw(nil))
        XCTAssertNil(WattageFormat.menuDraw(0))
        XCTAssertEqual(WattageFormat.menuDraw(0.001, locale: locale), "<1 W")
        XCTAssertEqual(WattageFormat.menuDraw(0.999, locale: locale), "<1 W")
        XCTAssertEqual(WattageFormat.menuDraw(1, locale: locale), "1 W")
        XCTAssertEqual(WattageFormat.menuDraw(39.51, locale: locale), "40 W")
    }

    func testProcessMetricsUseTheLocaleForSmallReadingsAndMulticoreCPU() {
        let french = Locale(identifier: "fr_FR")
        XCTAssertEqual(WattageFormat.processPower(0.002, locale: french), "<0,01 W")
        XCTAssertEqual(WattageFormat.processPower(0.234, locale: french), "0,23 W")
        let percent = FloatingPointFormatStyle<Double>.Percent.percent.locale(french)
        XCTAssertEqual(WattageFormat.cpuUsage(0.03, locale: french), "<" + 0.001.formatted(percent))
        XCTAssertEqual(WattageFormat.cpuUsage(245, locale: french), 2.45.formatted(percent))
        XCTAssertEqual(WattageFormat.cpuUsage(.infinity), "—")
        XCTAssertEqual(WattageFormat.processPower(-1), "—")
    }

    func testDetailedPowerDistinguishesUnavailableZeroAndSubtenthReadings() {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        XCTAssertEqual(WattageFormat.detail(nil), "—")
        XCTAssertEqual(WattageFormat.detail(0), 0.0.formatted(format) + " W")
        XCTAssertEqual(WattageFormat.detail(0.001), "<" + 0.1.formatted(format) + " W")
        XCTAssertEqual(WattageFormat.detail(0.1), 0.1.formatted(format) + " W")
    }
}
