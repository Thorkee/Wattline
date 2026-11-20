import XCTest
@testable import Wattline

final class MonitorChartTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func point(_ offset: Double, _ value: Double?, gap: Double = 6) -> MonitorPoint {
        MonitorPoint(date: origin.addingTimeInterval(offset), value: value, maximumGap: gap)
    }

    func testSelectionFollowsRealCadenceAndRespectsMissingIntervals() {
        let points = [point(0, 1, gap: 120), point(60, 2, gap: 120),
                      point(75, nil), point(120, 4, gap: 120), point(150, 5),
                      point(152, 6), point(302, 7)]
        let graph = MonitorChartTimeline(series: [.init(title: "CPU", color: .blue, points: points)],
                                         start: origin, end: origin.addingTimeInterval(400))
        func at(_ t: Double) -> Date? { graph.nearest(to: origin.addingTimeInterval(t)) }
        XCTAssertEqual(at(32), points[1].date)
        XCTAssertNil(at(80))
        XCTAssertEqual(at(138), points[4].date)
        XCTAssertNil(at(230))
        XCTAssertEqual(at(302), points.last?.date)
        XCTAssertEqual(graph.dates.count, 6)
        XCTAssertFalse(points[0].connects(to: points[0]))
        XCTAssertFalse(points[4].connects(to: points[0]))
        XCTAssertFalse(points[5].connects(to: points[6]))
    }

    func testClockTicksStayLocallyAlignedAcrossDSTAndFractionalTimeZones() throws {
        var calendar = Calendar(identifier: .gregorian)
        // The local midnight, 6 AM and noon ticks must retain their wall clock times after the clock change.
        for zoneName in ["America/Los_Angeles", "Asia/Kathmandu"] {
            let zone = try XCTUnwrap(TimeZone(identifier: zoneName))
            calendar.timeZone = zone
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 14)))
            let end = date.addingTimeInterval(86_400)
            let ticks = MonitorChartTimeline.ticks(start: date, end: end, width: 630, timeZone: zone)
            XCTAssertTrue((3...5).contains(ticks.count))
            XCTAssertTrue(ticks.contains { calendar.component(.hour, from: $0) == 0 })
            for tick in ticks {
                XCTAssertEqual(calendar.component(.hour, from: tick) % 6, 0)
                XCTAssertEqual(calendar.component(.minute, from: tick), 0)
                XCTAssertTrue(tick >= date && tick <= end)
            }
        }
    }

    func testPartialHistoryUsesFirstRealReadingAndPreservesOutageAtItsTruePosition() {
        let points = [point(0, nil), point(180, .infinity), point(400, -1),
                      point(2400, 0), point(2402, 1), point(2404, nil),
                      point(3000, 6), point(3600, 2)]
        let graph = MonitorChartTimeline(series: [.init(title: "Download", color: .blue, points: points)],
                                         start: origin, end: origin.addingTimeInterval(3600))
        XCTAssertTrue(graph.partial)
        XCTAssertEqual(graph.start, points[3].date)
        XCTAssertEqual(graph.span, 1200)
        XCTAssertEqual(graph.position(of: points[3].date), 0)
        XCTAssertEqual(graph.position(of: points[6].date), 0.5)
        XCTAssertEqual(graph.date(at: 0.5), points[6].date)
        XCTAssertNil(graph.nearest(to: graph.date(at: 0.25)))
    }

    func testFullRangeKeepsClockBoundaryWithinCadenceAndSingleReadingHasFinitePosition() {
        let end = origin.addingTimeInterval(3600)
        let series = MonitorSeries(title: "Read", color: .blue, points: [point(37, 1, gap: 120)])
        let full = MonitorChartTimeline(series: [series], start: origin, end: end)
        XCTAssertFalse(full.partial)
        XCTAssertEqual(full.start, origin)
        let empty = MonitorChartTimeline(series: [], start: origin, end: end)
        XCTAssertEqual(empty.span, 3600)
        XCTAssertNil(empty.peak)
        let lone = MonitorChartTimeline(series: [.init(title: "Read", color: .blue, points: [point(3600, 0)])],
                                        start: origin, end: end)
        XCTAssertTrue(lone.partial)
        XCTAssertEqual(lone.span, 0)
        XCTAssertEqual(lone.date(at: 0.5), end)
        XCTAssertEqual(lone.position(of: end), 1)
    }

    func testAdaptiveRateCeilingIncludesPeaksWithoutDoublingTheScale() {
        let burst = MonitorSeries(title: "Upload", color: .blue, points: [point(0, 300_000), point(1, 5_100_000)])
        let graph = MonitorChartTimeline(series: [burst], start: origin, end: origin.addingTimeInterval(60))
        let limit = graph.scaleCeiling(fallback: 10_000_000, adaptive: true)
        XCTAssertGreaterThan(limit, 5_100_000)
        XCTAssertLessThanOrEqual(limit, 6_000_000)
        XCTAssertEqual(graph.scaleCeiling(fallback: 10_000_000, adaptive: false), 10_000_000)
        let empty = MonitorChartTimeline(series: [], start: origin, end: origin.addingTimeInterval(60))
        XCTAssertEqual(empty.scaleCeiling(fallback: 1000, adaptive: true), 1000)
    }

    func testInvalidHistoryRangeCannotGenerateUnboundedTicks() {
        for value in [Int.min, 0, 120, Int.max] {
            XCTAssertEqual(WattlinePreferences.historyRange(value), 3_600)
        }
        XCTAssertEqual(WattlinePreferences.historyRange(86_400), 86_400)
        XCTAssertTrue(MonitorChartTimeline.ticks(start: .distantPast, end: .distantFuture, width: 640).isEmpty)
    }

    func testMemoryFormatHandlesEntirePersistedUnsignedRange() {
        let value = Double(UInt64.max)
        XCTAssertEqual(MonitorFormat.memoryReading(value), MonitorFormat.memory(UInt64.max))
        XCTAssertEqual(MonitorFormat.memory(8_589_934_592), MonitorFormat.memoryReading(8_589_934_592))
        XCTAssertEqual(MonitorFormat.memoryReading(-1), "—")
    }

    func testLiveBaselineDoesNotInterruptAvailableArchiveAtCustomCadences() {
        func sample(_ seconds: Double, cpu: Double?, begins: Bool) -> HistorySample {
            HistorySample(date: origin.addingTimeInterval(seconds), cpuPercent: cpu, memoryUsed: nil,
                          downloadBytesPerSecond: nil, uploadBytesPerSecond: nil, systemWatts: nil,
                          diskReadBytesPerSecond: nil, diskWriteBytesPerSecond: nil, startsSegment: begins)
        }
        let archived = sample(60, cpu: 10, begins: false)
        for interval in [2.0, 5, 10] {
            let first = sample(62, cpu: nil, begins: true)
            let second = sample(62 + interval, cpu: 20, begins: false)
            let timeline = MonitorTimeline.merge(archive: [archived], live: [first, second], from: origin,
                                                 through: second.date, liveGaps: [first.date: 3 * interval, second.date: 3 * interval])
            let series = MonitorSeries(title: "CPU", color: .blue, timeline: timeline, value: { $0.cpuPercent })
            XCTAssertEqual(series.points.map(\.value), [10, 20])
        }
    }

    @MainActor func testDensePlotPreservesSpikesAndEndpointOrder() {
        var points: [CGPoint] = []
        for i in 0..<1600 { points.append(CGPoint(x: CGFloat(i) / 10, y: 3)) }
        points[234].y = 1
        points[235].y = 9
        let reduced = MonitorChart.displayPoints(points, width: 160)
        XCTAssertEqual(reduced.first, points.first)
        XCTAssertEqual(reduced.last, points.last)
        XCTAssertTrue(reduced.contains(points[234]))
        XCTAssertTrue(reduced.contains(points[235]))
        XCTAssertEqual(reduced, reduced.sorted { $0.x < $1.x })
        XCTAssertLessThan(reduced.count, 325)
    }
}
