import Foundation
import XCTest
@testable import Wattline

final class StorageReportCacheTests: XCTestCase {
    private var root: URL!
    private var cache: StorageReportCache!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cache = StorageReportCache(fileURL: root.appendingPathComponent("apps.json"))
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func app(_ path: String = "/Applications/Sample.app") -> InventoryUpdate {
        let row = StorageEntry(url: URL(fileURLWithPath: path, isDirectory: true),
                               bytes: 4096, isPartial: true, isScanning: false)
        return InventoryUpdate(entries: [row], isComplete: true, hasSkippedItems: false)
    }

    func testLimitedResultRoundTripsWithOriginalDateAndOverallTotals() async throws {
        let date = Date(timeIntervalSince1970: 1_680_000_000)
        var snapshot = app("/System/Applications/Utilities/Test App.app")
        snapshot.reachedScanLimit = true
        snapshot.skippedNetworkVolume = true
        snapshot.measuredItemCount = 300
        snapshot.measuredBytes = 8_192
        cache.save(snapshot, at: date)
        let loaded = await cache.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.date, date)
        XCTAssertEqual(saved.update.entries.first?.url.lastPathComponent, "Test App.app")
        XCTAssertEqual(saved.update.entries.first?.bytes, 4096)
        XCTAssertEqual(saved.update.entries.first?.isPartial, true)
        XCTAssertTrue(saved.update.reachedScanLimit)
        XCTAssertTrue(saved.update.skippedNetworkVolume)
        XCTAssertEqual(saved.update.measuredItemCount, 300)
        XCTAssertEqual(saved.update.measuredBytes, 8_192)
    }

    func testFolderResultsAndInProgressUpdatesCannotReplaceApplicationReport() async throws {
        let date = Date(timeIntervalSince1970: 1_680_000_000)
        cache.save(app(), at: date)
        var folder = app()
        folder.directFileBytes = 0
        cache.save(folder, at: Date())
        cache.save(app("/private/tmp/Personal.app"), at: Date())
        cache.save(InventoryUpdate(entries: [], isComplete: false, hasSkippedItems: false), at: Date())
        let loaded = await cache.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.date, date)
        XCTAssertEqual(saved.update.entries.count, 1)
    }

    func testMalformedAndOversizedFilesAreIgnored() async throws {
        try Data([0xFF, 0xAB]).write(to: cache.fileURL)
        let malformed = await cache.load()
        XCTAssertNil(malformed)
        try Data(repeating: 0x20, count: 256 * 1024 + 1).write(to: cache.fileURL)
        let oversized = await cache.load()
        XCTAssertNil(oversized)
    }

    func testSharedAllocationsAndWriteOrderSurviveRoundTrip() async throws {
        let first = app("/Applications/First.app").entries[0]
        let second = app("/Applications/Second.app").entries[0]
        var both = InventoryUpdate(entries: [first, second], isComplete: true, hasSkippedItems: false)
        both.measuredBytes = 4096
        let latest = Date(timeIntervalSince1970: 1_680_000_001)
        cache.save(app(), at: latest.addingTimeInterval(-1))
        cache.save(both, at: latest)
        let loaded = await cache.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.date, latest)
        XCTAssertEqual(saved.update.entries.count, 2)
        XCTAssertEqual(saved.update.measuredBytes, 4096)
        let other = root.appendingPathComponent("other")
        try FileManager.default.moveItem(at: cache.fileURL, to: other)
        try FileManager.default.createSymbolicLink(at: cache.fileURL, withDestinationURL: other)
        let linked = await cache.load()
        XCTAssertNil(linked)
    }
}
