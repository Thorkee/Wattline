import XCTest
@testable import Wattline

final class MonitorLifecycleTests: XCTestCase {
    private func sample(_ seconds: TimeInterval) -> PowerReading {
        PowerReading.decode(registry: [:], date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    func testShortSleepCreatesGapAndTimerNotificationsCanCoincide() {
        var timeline = PowerTimeline()
        timeline.record(sample(20), uptime: 10)
        timeline.record(sample(20.1), uptime: 10.1)
        timeline.record(sample(22), uptime: 11, afterSleep: true)
        timeline.record(sample(22), uptime: 11)
        XCTAssertEqual(timeline.samples.map(\.date), [sample(20).date, sample(22).date])
        XCTAssertEqual(timeline.breaks, [sample(22).date])
    }

    func testClockJumpsAndRetentionDoNotJoinUnrelatedReadings() {
        var timeline = PowerTimeline()
        timeline.record(sample(100), uptime: 10)
        timeline.record(sample(108), uptime: 11)
        XCTAssertEqual(timeline.breaks, [sample(108).date])
        timeline.record(sample(90), uptime: 12)
        XCTAssertEqual(timeline.samples.map(\.date), [sample(90).date])
        XCTAssertTrue(timeline.breaks.isEmpty)
        timeline.record(sample(1_000), uptime: 922)
        XCTAssertEqual(timeline.samples.map(\.date), [sample(1_000).date])
    }

    func testShortcutAndSettingsStayWithinOffsetAndSmallDisplays() {
        let size = CGSize(width: 310, height: 258)
        for area in [CGRect(x: -1024, y: -300, width: 1024, height: 740),
                     CGRect(x: 1512, y: 368, width: 1920, height: 1080),
                     CGRect(x: -300, y: 500, width: 245, height: 180)] {
            for anchor in [WindowPlacement.Anchor.center, .topTrailing] {
                let frame = WindowPlacement.frame(size: size, in: area, anchor: anchor)
                XCTAssertTrue(area.contains(frame))
                XCTAssertEqual(frame.size, CGSize(width: min(size.width, area.width), height: min(size.height, area.height)))
            }
        }
    }
}
