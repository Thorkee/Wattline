import Foundation
import XCTest
@testable import Wattline

final class MonitorTimelineTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func row(_ seconds: Double, cpu: Double? = nil, begins: Bool = false) -> HistorySample {
        HistorySample(date: epoch.addingTimeInterval(seconds), cpuPercent: cpu, memoryUsed: nil,
                      downloadBytesPerSecond: nil, uploadBytesPerSecond: nil, systemWatts: nil,
                      diskReadBytesPerSecond: nil, diskWriteBytesPerSecond: nil, startsSegment: begins)
    }

    private func merge(_ archive: [HistorySample], _ live: [HistorySample],
                       start: Double = 0, end: Double = 1000) -> [TimelineSample] {
        MonitorTimeline.merge(archive: archive, live: live, from: epoch.addingTimeInterval(start),
                              through: epoch.addingTimeInterval(end))
    }

    private func times(_ samples: [TimelineSample]) -> [Double] {
        samples.map { $0.sample.date.timeIntervalSince(epoch) }
    }

    func testFillsBetweenLiveSessionsAndPrefersLiveWithinEachRun() {
        let result = merge([row(0), row(60), row(120), row(180)],
                           [row(58, begins: true), row(60, cpu: 2), row(62), row(179, begins: true), row(181)])
        XCTAssertEqual(times(result), [0, 58, 60, 62, 120, 179, 181])
        XCTAssertEqual(result.map(\.maximumGap), [95, 6, 6, 6, 95, 6, 6])
        XCTAssertEqual(result[2].sample.cpuPercent, 2)
        XCTAssertTrue(result.allSatisfy { !$0.startsSegment })
    }

    func testArchiveBoundaryInsideLiveRunReachesNextPlottedSample() {
        let result = merge([row(11, begins: true)], [row(10), row(12), row(14)])
        XCTAssertEqual(times(result), [10, 12, 14])
        XCTAssertEqual(result.map(\.startsSegment), [false, true, false])
    }

    func testMissingMinuteAndDiscontinuousLiveSamplesBreakCharts() {
        let result = merge([row(0), row(120)], [row(122, begins: true), row(126), row(140), row(142, begins: true)])
        XCTAssertEqual(result.map(\.startsSegment), [false, true, false, false, true, true])
    }

    func testPartialBaselineUsesOnlyIdenticallyTimedArchiveMeasurements() {
        let result = merge([row(30, cpu: 7), row(60, cpu: 20)],
                           [row(60, begins: true), row(62, cpu: 12)])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[1].sample.cpuPercent, 20)
        XCTAssertFalse(result[1].startsSegment)
        let different = merge([row(60, cpu: 20)], [row(61, begins: true), row(63, cpu: 12)])
        XCTAssertNil(different[1].sample.cpuPercent)
        XCTAssertFalse(different[1].startsSegment)
    }

    func testCoalescesDuplicateDatesAndKeepsRangeInclusive() {
        let result = merge([row(0), row(10, begins: true), row(10, cpu: 8), row(80)],
                           [row(10, cpu: 3), row(10, cpu: 4), row(12), row(90)], start: 10, end: 80)
        XCTAssertEqual(times(result), [10, 12, 80])
        XCTAssertEqual(result.first?.sample.cpuPercent, 4)
        XCTAssertTrue(result.first?.startsSegment == true)
        XCTAssertTrue(merge([row(10)], [row(20)], start: 20, end: 10).isEmpty)
    }

    func testRefreshCadenceKeepsTenSecondSamplesConnectedAndPreservesOldGaps() {
        let live = [row(0), row(10), row(20), row(22, begins: true), row(24), row(35)]
        let tolerances = Dictionary(uniqueKeysWithValues: zip(live.map(\.date), [30.0, 30, 30, 6, 6, 6]))
        let merged = MonitorTimeline.merge(archive: [row(6)], live: live, from: epoch,
                                           through: epoch.addingTimeInterval(40), liveGaps: tolerances)
        XCTAssertEqual(times(merged), [0, 10, 20, 22, 24, 35])
        XCTAssertEqual(merged.map(\.maximumGap), [30, 30, 30, 6, 6, 6])
        XCTAssertEqual(merged.map(\.startsSegment), [false, false, false, true, false, true])
    }

    func testClockReversalStartsFreshEvenWithNearbyBackgroundHistory() {
        let result = merge([row(30)], [row(80), row(90), row(38), row(40)])
        XCTAssertEqual(times(result), [30, 38, 40])
        XCTAssertTrue(result[1].startsSegment)
    }
}
