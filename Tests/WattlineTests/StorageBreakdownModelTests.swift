import Combine
import Foundation
import XCTest
@testable import Wattline

@MainActor
private final class InventoryScanProbe {
    var scopes: [InventoryScope] = []
    var latest: AsyncStream<InventoryUpdate>.Continuation?

    func scan(_ scope: InventoryScope) -> AsyncStream<InventoryUpdate> {
        scopes.append(scope)
        let (stream, continuation) = AsyncStream<InventoryUpdate>.makeStream()
        latest = continuation
        return stream
    }
}

private actor DeferredStorageCache: StorageReportCaching {
    let started: XCTestExpectation
    private var pending: CheckedContinuation<DatedStorageReport?, Never>?
    private(set) var reads = 0

    init(_ started: XCTestExpectation) { self.started = started }

    func load() async -> DatedStorageReport? {
        await withCheckedContinuation { continuation in
            reads += 1
            pending = continuation
            started.fulfill()
        }
    }

    func finish(at date: Date) {
        pending?.resume(returning: (InventoryUpdate(entries: [], isComplete: true, hasSkippedItems: false), date))
        pending = nil
    }

    nonisolated func save(_ update: InventoryUpdate, at date: Date) {}
}

final class StorageBreakdownModelTests: XCTestCase {
    @MainActor
    func testSlowCacheReadSurvivesNavigationAndReactivatingWithoutIndexing() async throws {
        let started = expectation(description: "Application cache read started")
        let cache = DeferredStorageCache(started)
        let probe = InventoryScanProbe()
        let model = StorageBreakdownModel(scan: probe.scan, cache: cache)
        model.setAutomaticScanning(false)
        model.setActive(true)
        await fulfillment(of: [started], timeout: 2)
        model.selectFolders()
        model.setActive(false)
        model.selectApps()
        let restored = expectation(description: "Restored on returning to Applications")
        let date = Date(timeIntervalSince1970: 1_680_000_000)
        let observation = model.$phase.first(where: { $0 == .complete(date) }).sink { _ in restored.fulfill() }
        defer { observation.cancel() }
        await cache.finish(at: date)
        XCTAssertEqual(model.phase, .idle)
        model.setActive(true)
        await fulfillment(of: [restored], timeout: 2)
        let reads = await cache.reads
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(probe.scopes.isEmpty)
    }

    @MainActor
    func testExplicitScanWinsRaceWithOldAppCache() async throws {
        let started = expectation(description: "Read delayed on disk")
        let cache = DeferredStorageCache(started)
        let probe = InventoryScanProbe()
        let model = StorageBreakdownModel(scan: probe.scan, cache: cache)
        model.setAutomaticScanning(false)
        model.setActive(true)
        await fulfillment(of: [started], timeout: 2)
        model.measure()
        let stream = try XCTUnwrap(probe.latest)
        let staleDate = Date(timeIntervalSince1970: 1_680_000_000)
        let stale = expectation(description: "Stale report was installed")
        stale.isInverted = true
        let observed = model.$phase.sink { if $0 == .complete(staleDate) { stale.fulfill() } }
        defer { observed.cancel() }
        await cache.finish(at: staleDate)
        stream.yield(InventoryUpdate(entries: [], isComplete: true, hasSkippedItems: false))
        stream.finish()
        await fulfillment(of: [stale], timeout: 0.12)
        model.selectFolders()
        model.selectApps()
        guard case .complete(let actual) = model.phase else { return XCTFail("New scan result missing") }
        XCTAssertGreaterThan(actual, staleDate)
        XCTAssertEqual(probe.scopes, [.apps])
    }

    @MainActor
    func testManualModeOnlyStartsAnExplicitScan() {
        let probe = InventoryScanProbe()
        let model = StorageBreakdownModel(scan: probe.scan)
        model.setAutomaticScanning(false)
        model.setActive(true)
        model.selectFolders()
        model.selectApps()
        model.setActive(false)
        model.setActive(true)
        XCTAssertTrue(probe.scopes.isEmpty)
        model.measure()
        model.measure()
        XCTAssertEqual(probe.scopes, [.apps])
        model.stop()
        model.setActive(false)
        model.setActive(true)
        XCTAssertEqual(probe.scopes, [.apps])
        probe.latest?.finish()
    }

    @MainActor
    func testLeavingMidScanCancelsWorkAndKeepsProgressAcrossNavigation() async throws {
        let probe = InventoryScanProbe()
        let model = StorageBreakdownModel(scan: probe.scan)
        let folder = URL(fileURLWithPath: "/storage-test", isDirectory: true)
        model.enter(folder, asRoot: true)
        XCTAssertTrue(probe.scopes.isEmpty)
        model.setActive(true)
        let first = try XCTUnwrap(probe.latest)
        let received = expectation(description: "Intermediate disk usage received")
        let observed = model.$update.compactMap { $0 }.first().sink { _ in received.fulfill() }
        defer { observed.cancel() }
        let ended = expectation(description: "Hidden scanner cancelled")
        first.onTermination = { reason in
            if case .cancelled = reason { ended.fulfill() }
        }
        first.yield(InventoryUpdate(entries: [], isComplete: false, hasSkippedItems: false, directFileBytes: 2048))
        await fulfillment(of: [received], timeout: 2)

        model.setActive(false)
        await fulfillment(of: [ended], timeout: 2)
        model.setActive(true)
        model.selectApps()
        model.selectFolders()
        XCTAssertEqual(probe.scopes, [.folder(folder), .apps])
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.update?.directFileBytes, 2048)

        model.measure()
        model.measure()
        XCTAssertEqual(probe.scopes, [.folder(folder), .apps, .folder(folder)])
        model.stop()
        model.setActive(false)
        model.setActive(true)
        XCTAssertEqual(probe.scopes.count, 3)
        probe.latest?.finish()
    }

    @MainActor
    func testCompletedScopeDoesNotRescanUntilExplicitlyRefreshed() async throws {
        let probe = InventoryScanProbe()
        let model = StorageBreakdownModel(scan: probe.scan)
        let finished = expectation(description: "App scan completed")
        let observed = model.$phase.sink { phase in
            if case .complete = phase { finished.fulfill() }
        }
        model.setActive(true)
        let first = try XCTUnwrap(probe.latest)
        first.yield(InventoryUpdate(entries: [], isComplete: true, hasSkippedItems: false))
        first.finish()
        await fulfillment(of: [finished], timeout: 2)
        observed.cancel()

        model.selectFolders()
        model.selectApps()
        model.setActive(false)
        model.setActive(true)
        model.selectApps()
        XCTAssertEqual(probe.scopes.filter { $0 == .apps }.count, 1)
        guard case .complete = model.phase else { return XCTFail("Expected a cached completed scan") }
        model.measure()
        XCTAssertEqual(probe.scopes.filter { $0 == .apps }.count, 2)
        model.stop()
        probe.latest?.finish()
    }

    @MainActor
    func testBudgetLimitedScanDoesNotStartAnotherBatchWhenRevisited() async throws {
        let probe = InventoryScanProbe()
        let model = StorageBreakdownModel(scan: probe.scan)
        let paused = expectation(description: "Limited scan published")
        let observed = model.$update.compactMap { $0 }.first(where: { $0.reachedScanLimit }).sink { _ in
            paused.fulfill()
        }
        model.setActive(true)
        let first = try XCTUnwrap(probe.latest)
        first.yield(InventoryUpdate(entries: [], isComplete: true, hasSkippedItems: false, reachedScanLimit: true))
        first.finish()
        await fulfillment(of: [paused], timeout: 2)
        observed.cancel()

        model.setActive(false)
        model.setActive(true)
        model.selectFolders()
        model.selectApps()
        XCTAssertEqual(probe.scopes.filter { $0 == .apps }.count, 1)
        XCTAssertEqual(model.update?.reachedScanLimit, true)
        model.setActive(false)
    }
}
