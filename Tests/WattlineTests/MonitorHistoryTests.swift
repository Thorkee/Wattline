import Foundation
import SQLite3
import XCTest
@testable import Wattline

final class MonitorHistoryTests: XCTestCase {
    private func sample(_ time: Double, newSegment: Bool = false, watts: Double? = 0) -> HistorySample {
        HistorySample(date: Date(timeIntervalSince1970: time), cpuPercent: nil, memoryUsed: 16_000_000_000,
                      downloadBytesPerSecond: nil, uploadBytesPerSecond: 0, systemWatts: watts,
                      diskReadBytesPerSecond: 5_120, diskWriteBytesPerSecond: nil, startsSegment: newSegment)
    }

    private func databaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.sqlite3")
    }

    private func execute(_ sql: String, at url: URL) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    func testMinuteScheduleSuppressesDuplicateTicksAndBreaksAtClockChanges() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var schedule = ArchiveSchedule()
        XCTAssertTrue(schedule.request(at: date, uptime: 50).newSegment)
        XCTAssertFalse(schedule.request(at: date, uptime: 50).due)
        XCTAssertFalse(schedule.request(at: date.addingTimeInterval(59), uptime: 109).due)
        let next = schedule.request(at: date.addingTimeInterval(60), uptime: 110)
        XCTAssertTrue(next.due)
        XCTAssertFalse(next.newSegment)
        XCTAssertTrue(schedule.request(at: date.addingTimeInterval(4), uptime: 115).newSegment)
        XCTAssertTrue(schedule.request(at: date.addingTimeInterval(1404), uptime: 1515).newSegment)
        schedule = ArchiveSchedule()
        XCTAssertTrue(schedule.request(at: date.addingTimeInterval(1410), uptime: 1521).newSegment)
    }

    func testMinuteArchiveRestoresPersistsGapsAndPrunesAfterClockRollback() async {
        let url = databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = HistoryDatabase(url: url)
        let base = 1_800_000_000.0
        await db.append(sample(base - 86_401))
        await db.append(sample(base - 86_400))
        await db.append(sample(base - 600))
        await db.append(sample(base - 300))
        await db.append(sample(base - 290, newSegment: true, watts: 27))
        await db.append(sample(base))
        let reopened = HistoryDatabase(url: url)
        let points = await reopened.load(at: Date(timeIntervalSince1970: base)) ?? []
        XCTAssertEqual(points.map { $0.date.timeIntervalSince1970 }, [base - 86_400, base - 600, base - 290, base])
        XCTAssertEqual(points[2].memoryUsed, 16_000_000_000)
        XCTAssertEqual(points[2].systemWatts, 27)
        XCTAssertNil(points[2].cpuPercent)
        XCTAssertEqual(points[2].uploadBytesPerSecond, 0)
        XCTAssertEqual(points[2].diskReadBytesPerSecond, 5_120)
        XCTAssertTrue(points[1].startsSegment)
        XCTAssertTrue(points[2].startsSegment)
        await reopened.append(sample(base - 2_000, newSegment: true))
        let rolledBack = await db.load(at: Date(timeIntervalSince1970: base)) ?? []
        XCTAssertEqual(rolledBack.map { $0.date.timeIntervalSince1970 }, [base - 86_400, base - 2_000])
    }

    func testCorruptRowCannotBridgeValidSamplesOrDestroyUnknownVersion() async {
        let url = databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = HistoryDatabase(url: url)
        let base = 1_800_000_000.0
        for offset in [0.0, 60, 120] { await db.append(sample(base + offset)) }
        execute("UPDATE history SET payload=X'10' WHERE minute=30000001", at: url)
        let result = await db.load(at: Date(timeIntervalSince1970: base + 120)) ?? []
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.last?.startsSegment == true)
        execute("PRAGMA user_version=9", at: url)
        await db.append(sample(base + 180))
        let unknown = await db.load(at: Date(timeIntervalSince1970: base + 180))
        XCTAssertNil(unknown)
        execute("PRAGMA user_version=1", at: url)
        let preserved = await db.load(at: Date(timeIntervalSince1970: base + 180)) ?? []
        XCTAssertEqual(preserved.map { $0.date.timeIntervalSince1970 }, [base, base + 120])
    }

    @MainActor
    func testUnreadableArchiveIsRetriedAtNextSamplingOpportunity() async throws {
        let url = databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = HistoryDatabase(url: url)
        let older = sample(Date().timeIntervalSince1970 - 180, watts: 11)
        await db.append(older)
        execute("PRAGMA user_version=9", at: url)
        let history = MonitorHistory(database: db)
        defer { history.pause() }
        history.sampleIfDue(PowerReading.decode(registry: [:]), uptime: 0)
        for _ in 0..<100 where history.samples.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(history.samples.count, 1)
        execute("PRAGMA user_version=1", at: url)
        history.sampleIfDue(PowerReading.decode(registry: [:]), uptime: 61)
        for _ in 0..<100 where history.samples.first?.date != older.date { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(history.samples.first?.date, older.date)
    }

    @MainActor
    func testRestoringArchivePreservesLiveMinutesAndClockBoundaries() {
        let base = 1_800_000_000.0
        let archived = [sample(base), sample(base + 60, newSegment: true, watts: 8)]
        let live = [sample(base - 86_400), sample(base + 65, watts: 17), sample(base + 120), sample(base + 600)]
        let merged = MonitorHistory.restore(archived, keeping: live, at: Date(timeIntervalSince1970: base + 200))
        XCTAssertEqual(merged.map { $0.date.timeIntervalSince1970 }, [base, base + 65, base + 120])
        XCTAssertEqual(merged[1].systemWatts, 17)
        XCTAssertTrue(merged[1].startsSegment)
    }

    @MainActor
    func testNewSessionPreservesHistoryAndCommitsSampleBeforePublication() async throws {
        let url = databaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = HistoryDatabase(url: url)
        let older = sample(Date().timeIntervalSince1970 - 90, newSegment: true, watts: 15)
        await db.append(older)
        let history = MonitorHistory(database: db)
        history.sampleIfDue(PowerReading.decode(registry: [:]), uptime: 0)
        for _ in 0..<100 where history.samples.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(history.samples.first?.systemWatts, 15)
        XCTAssertEqual(history.samples.count, 2)
        XCTAssertTrue(history.samples.last?.startsSegment == true)
        history.pause()
        let restored = await HistoryDatabase(url: url).load(at: Date()) ?? []
        XCTAssertEqual(restored.map(\.date), history.samples.map(\.date))
    }
}
