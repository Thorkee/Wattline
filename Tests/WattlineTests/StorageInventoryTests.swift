import Darwin
import Foundation
import XCTest
@testable import Wattline

final class StorageInventoryTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try directory(root)
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    private func directory(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }

    private func bytes(_ url: URL) throws -> UInt64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return UInt64(info.st_blocks) * 512
    }

    private func final(_ scope: InventoryScope, appRoots: [URL]? = nil,
                       limits: StorageScanLimits = StorageScanLimits()) async throws -> InventoryUpdate {
        var last: InventoryUpdate?
        for await sample in StorageInventory.scan(scope, applicationDirectories: appRoots, limits: limits) {
            last = sample
        }
        let update = try XCTUnwrap(last)
        XCTAssertTrue(update.isComplete)
        XCTAssertFalse(update.entries.contains { $0.isScanning })
        return update
    }

    func testRanksImmediateFoldersIncludingHiddenAndReportsDirectFiles() async throws {
        let small = root.appendingPathComponent(".hidden")
        let large = root.appendingPathComponent("Large")
        let nested = large.appendingPathComponent("Subfolder")
        try directory(small)
        try directory(nested)
        let loose = root.appendingPathComponent("loose")
        let leaf = nested.appendingPathComponent("payload")
        try Data(repeating: 0x43, count: 4096).write(to: loose)
        try Data(repeating: 0x98, count: 131072).write(to: leaf)
        let result = try await final(.folder(root))
        XCTAssertEqual(result.entries.map { $0.url.lastPathComponent }, ["Large", ".hidden"])
        XCTAssertEqual(result.directFileBytes, try bytes(loose))
        XCTAssertEqual(result.entries[0].bytes, try bytes(large) + bytes(nested) + bytes(leaf))
        XCTAssertFalse(result.hasSkippedItems)
        let drilled = try await final(.folder(nested))
        XCTAssertTrue(drilled.entries.isEmpty)
        XCTAssertEqual(drilled.directFileBytes, try bytes(leaf))
    }

    func testHardLinksCountOncePerEntryAndSparseFilesUseAllocatedBytes() async throws {
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try directory(a)
        try directory(b)
        let file = a.appendingPathComponent("data")
        try Data(repeating: 0x61, count: 8192).write(to: file)
        XCTAssertEqual(link(file.path, a.appendingPathComponent("second").path), 0)
        XCTAssertEqual(link(file.path, b.appendingPathComponent("other").path), 0)
        XCTAssertEqual(link(file.path, root.appendingPathComponent("loose").path), 0)
        let sparse = a.appendingPathComponent("sparse")
        try Data([0]).write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: 32 * 1024 * 1024)
        try handle.close()
        let result = try await final(.folder(root))
        let aRow = try XCTUnwrap(result.entries.first { $0.url.lastPathComponent == "A" })
        let bRow = try XCTUnwrap(result.entries.first { $0.url.lastPathComponent == "B" })
        XCTAssertEqual(aRow.bytes, try bytes(a) + bytes(file) + bytes(sparse))
        XCTAssertEqual(bRow.bytes, try bytes(b) + bytes(file))
        XCTAssertEqual(result.directFileBytes, try bytes(file))
        XCTAssertEqual(result.measuredBytes, try bytes(a) + bytes(b) + bytes(file) + bytes(sparse))
        XCTAssertFalse(result.hasSkippedItems)
    }

    func testDoesNotFollowDirectorySymlinksOrSymlinkRoot() async throws {
        let real = root.appendingPathComponent("Real")
        try directory(real)
        let pointer = root.appendingPathComponent("Pointer")
        try fm.createSymbolicLink(at: pointer, withDestinationURL: real)
        let loop = real.appendingPathComponent("Loop")
        try fm.createSymbolicLink(at: loop, withDestinationURL: root)
        let regular = real.appendingPathComponent("file")
        try Data(repeating: 0x72, count: 4096).write(to: regular)
        let result = try await final(.folder(root))
        XCTAssertEqual(result.entries.map { $0.url.lastPathComponent }, ["Real"])
        XCTAssertEqual(result.entries.first?.bytes, try bytes(real) + bytes(loop) + bytes(regular))
        let rootedAtLink = try await final(.folder(pointer))
        XCTAssertTrue(rootedAtLink.entries.isEmpty)
        XCTAssertTrue(rootedAtLink.hasSkippedItems)
    }

    func testReportsInstalledAppsInsideCategoryFoldersAndGroupsEmbeddedHelpers() async throws {
        let utilities = root.appendingPathComponent("Utilities")
        let outer = utilities.appendingPathComponent("Parent.app")
        let helper = outer.appendingPathComponent("Contents/Frameworks/Embedded.app")
        let smaller = root.appendingPathComponent("Small.app")
        try directory(helper)
        try directory(smaller)
        let file = helper.appendingPathComponent("payload")
        try Data(repeating: 0x6B, count: 16384).write(to: file)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Alias.app"), withDestinationURL: outer)
        let result = try await final(.apps, appRoots: [root, root.appendingPathComponent("nonexistent"), root])
        XCTAssertEqual(result.entries.map { $0.url.lastPathComponent }, ["Parent.app", "Small.app"])
        XCTAssertGreaterThanOrEqual(result.entries[0].bytes, try bytes(file))
        XCTAssertFalse(result.hasSkippedItems)
        XCTAssertNil(result.directFileBytes)
    }

    func testSkippedEntriesAreDistinctFromAnEmptyReadableFolder() async throws {
        let missing = try await final(.folder(root.appendingPathComponent("missing")))
        let empty = try await final(.folder(root))
        XCTAssertTrue(missing.hasSkippedItems)
        XCTAssertFalse(empty.hasSkippedItems)
        guard geteuid() != 0 else { return }
        let privateDir = root.appendingPathComponent("Locked")
        try directory(privateDir)
        let privateFile = privateDir.appendingPathComponent("stored")
        try Data(repeating: 0x99, count: 32768).write(to: privateFile)
        XCTAssertEqual(chmod(privateDir.path, 0), 0)
        defer { chmod(privateDir.path, 0o700) }
        let partial = try await final(.folder(root))
        XCTAssertTrue(partial.hasSkippedItems)
        XCTAssertTrue(try XCTUnwrap(partial.entries.first { $0.url.lastPathComponent == "Locked" }).isPartial)
    }

    func testEntryBudgetReturnsALowerBoundForAnUnfinishedFolder() async throws {
        let folder = root.appendingPathComponent("Large")
        try directory(folder)
        for index in 0..<40 {
            try Data(repeating: UInt8(index), count: 8192).write(to: folder.appendingPathComponent("item-\(index)"))
        }
        let full = try await final(.folder(root))
        XCTAssertFalse(full.reachedScanLimit)
        let limited = try await final(.folder(root), limits: StorageScanLimits(maxEntries: 8))
        XCTAssertTrue(limited.reachedScanLimit)
        let entry = try XCTUnwrap(limited.entries.first)
        XCTAssertEqual(entry.url.lastPathComponent, "Large")
        XCTAssertTrue(entry.isPartial)
        XCTAssertLessThan(entry.bytes, try XCTUnwrap(full.entries.first).bytes)
    }

    func testAppDiscoveryAndSeparateRootsShareOneEntryBudget() async throws {
        let first = root.appendingPathComponent("First")
        let second = root.appendingPathComponent("Second")
        for index in 0..<24 { try directory(first.appendingPathComponent("category-\(index)")) }
        try directory(second.appendingPathComponent("Late.app"))
        let limited = try await final(.apps, appRoots: [first, second], limits: StorageScanLimits(maxEntries: 12))
        XCTAssertTrue(limited.reachedScanLimit)
        XCTAssertTrue(limited.entries.isEmpty)
        let full = try await final(.apps, appRoots: [first, second])
        XCTAssertEqual(full.entries.map { $0.url.lastPathComponent }, ["Late.app"])
        XCTAssertFalse(full.reachedScanLimit)
    }

    func testZeroTimeBudgetFinishesWithoutReportingAnEmptySuccessfulScan() async throws {
        try directory(root.appendingPathComponent("one"))
        let result = try await final(.folder(root), limits: StorageScanLimits(maxDuration: 0))
        XCTAssertTrue(result.reachedScanLimit)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testContinuingSmallBatchesFinishesWithExactOneShotSizes() async throws {
        let first = root.appendingPathComponent("A/Nested")
        let second = root.appendingPathComponent("B")
        try directory(first)
        try directory(second)
        for index in 0..<14 {
            let folder = index.isMultiple(of: 2) ? first : second
            try Data(repeating: UInt8(index), count: 8192).write(to: folder.appendingPathComponent("item-\(index)"))
        }
        try Data(repeating: 0x41, count: 8192).write(to: root.appendingPathComponent("loose"))
        try fm.linkItem(at: first.appendingPathComponent("item-0"), to: first.appendingPathComponent("alias"))

        let expected = try await final(.folder(root))
        let session = StorageInventorySession(.folder(root), limits: StorageScanLimits(maxEntries: 5))
        defer { session.cancel() }
        var finalBatch: InventoryUpdate?
        var limitedBatches = 0
        for _ in 0..<60 {
            var last: InventoryUpdate?
            for await update in session.nextBatch() { last = update }
            let terminal = try XCTUnwrap(last)
            XCTAssertTrue(terminal.isComplete)
            XCTAssertFalse(terminal.entries.contains { $0.isScanning })
            if !terminal.reachedScanLimit {
                finalBatch = terminal
                break
            }
            limitedBatches += 1
        }
        XCTAssertGreaterThan(limitedBatches, 0)
        let measured = try XCTUnwrap(finalBatch, "Continuation must advance through the tree")
        XCTAssertEqual(measured.entries.map(\.url), expected.entries.map(\.url))
        XCTAssertEqual(measured.entries.map(\.bytes), expected.entries.map(\.bytes))
        XCTAssertEqual(measured.directFileBytes, expected.directFileBytes)
        XCTAssertEqual(measured.measuredBytes, expected.measuredBytes)
        XCTAssertFalse(measured.hasSkippedItems)
        XCTAssertFalse(measured.entries.contains { $0.isPartial })
    }

    func testCancellingALimitedSessionPreventsFurtherTraversal() async throws {
        for index in 0..<8 { try directory(root.appendingPathComponent("folder-\(index)")) }
        let session = StorageInventorySession(.folder(root), limits: StorageScanLimits(maxEntries: 3))
        var limited: InventoryUpdate?
        for await update in session.nextBatch() { limited = update }
        XCTAssertTrue(try XCTUnwrap(limited).reachedScanLimit)
        session.cancel()
        for await _ in session.nextBatch() { XCTFail("Cancelled sessions should not emit results") }
    }

    func testRemoteMountFilterRecognizesVolumeAliasesAndComponentBoundaries() {
        let filter = StorageMountFilter(excludedPaths: ["/Volumes/Team"])
        for alias in ["/Volumes", "/System/Volumes/Data/Volumes"] {
            XCTAssertTrue(filter.excludes("\(alias)/Team"))
            XCTAssertTrue(filter.excludes("\(alias)/Team/Design/Assets"))
            XCTAssertFalse(filter.excludes("\(alias)/Teammate"))
            XCTAssertFalse(filter.excludes("\(alias)/Teammate/Design"))
            XCTAssertFalse(filter.excludes(alias))
        }
        let dataPathFilter = StorageMountFilter(excludedPaths: ["/System/Volumes/Data/Volumes/Team"])
        XCTAssertTrue(dataPathFilter.excludes("/Volumes/Team/Design"))
    }

    func testLocalMountIsPrunedEvenWithSameDeviceAndCanBeScannedAsItsOwnRoot() async throws {
        let canonical = try XCTUnwrap(root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let base = URL(fileURLWithPath: canonical, isDirectory: true)
        let local = base.appendingPathComponent("NestedMount", isDirectory: true)
        let nested = local.appendingPathComponent("OnlyInside", isDirectory: true)
        let remote = base.appendingPathComponent("Remote", isDirectory: true)
        let sibling = base.appendingPathComponent("Neighbor", isDirectory: true)
        try directory(nested)
        try directory(sibling)
        let mountTable = StorageMountFilter(excludedPaths: [remote.path], localMountPaths: [local.path])
        func scan(_ url: URL) async throws -> InventoryUpdate {
            let session = StorageInventorySession(.folder(url), mountTable: { mountTable })
            var last: InventoryUpdate?
            for await update in session.nextBatch() { last = update }
            return try XCTUnwrap(last)
        }

        let parent = try await scan(base)
        XCTAssertEqual(parent.entries.map { $0.url.lastPathComponent }, ["Neighbor"])
        XCTAssertTrue(parent.hasSkippedItems)
        XCTAssertFalse(parent.skippedNetworkVolume)
        let selected = try await scan(local)
        XCTAssertEqual(selected.entries.map { $0.url.lastPathComponent }, ["OnlyInside"])
        XCTAssertFalse(selected.hasSkippedItems)
        let network = try await scan(remote)
        XCTAssertTrue(network.skippedNetworkVolume)
        XCTAssertTrue(network.entries.isEmpty)
    }

    func testCappedRankingStillIncludesEveryMeasuredItemInTheTotals() async throws {
        var total: UInt64 = 0
        for index in 0..<259 {
            let folder = root.appendingPathComponent("Folder-\(index)")
            try directory(folder)
            let file = folder.appendingPathComponent("item")
            let size = index == 258 ? 131072 : 4096
            try Data(repeating: 0x4C, count: size).write(to: file)
            total += try bytes(folder) + bytes(file)
        }
        let loose = root.appendingPathComponent("loose")
        try Data(repeating: 0x58, count: 8192).write(to: loose)
        total += try bytes(loose)
        let report = try await final(.folder(root))
        XCTAssertEqual(report.measuredItemCount, 259)
        XCTAssertEqual(report.measuredBytes, total)
        XCTAssertEqual(report.entries.count, 256)
        XCTAssertEqual(report.entries.first?.url.lastPathComponent, "Folder-258")
        XCTAssertFalse(report.hasSkippedItems)
        XCTAssertFalse(report.reachedScanLimit)
    }
}
