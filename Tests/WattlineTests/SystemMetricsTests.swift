import XCTest
@testable import Wattline

final class SystemMetricsTests: XCTestCase {
    func testMemoryHistoryUsesMeasuredByteCount() {
        let bytes: UInt64 = 21_474_836_480
        let sample = SystemSample(date: Date(), cpuPercent: nil, memoryUsed: bytes, memoryTotal: 25_769_803_776,
                                  swapUsed: nil, downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                                  networkInterfaces: [])
        XCTAssertEqual(sample.memoryBytesForChart, 21_474_836_480.0)
    }

    private let zero = SystemCounters.CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    private let wifi = SystemCounters.Link(name: "en0", index: 8)
    private let ethernet = SystemCounters.Link(name: "en1", index: 10)

    private func snapshot(_ cpu: SystemCounters.CPUTicks? = nil,
                          links: [SystemCounters.Link: SystemCounters.Traffic]? = nil,
                          uptime: Double = 20, wall: Double = 20) -> SystemCounters {
        SystemCounters(date: Date(timeIntervalSince1970: wall), uptime: uptime, cpu: cpu, links: links)
    }

    func testCPUReportsWholeMachinePercentIncludingNiceAndHandlesReset() {
        let current = snapshot(.init(user: 10, system: 5, idle: 20, nice: 5))
        XCTAssertEqual(current.cpuLoad(since: zero)?.user, 37.5)
        XCTAssertEqual(current.cpuLoad(since: zero)?.system, 12.5)
        XCTAssertNil(current.cpuLoad(since: nil))
        XCTAssertNil(current.cpuLoad(since: current.cpu))
        XCTAssertNil(current.cpuLoad(since: .init(user: UInt32.max, system: 0, idle: 0, nice: 0)))
        XCTAssertEqual(snapshot(.init(user: 0, system: 0, idle: 99, nice: 0)).cpuLoad(since: zero)?.user, 0)
    }

    func testNetworkUses64BitPerLinkDeltasIncludingIdleLinks() {
        let base = UInt64(UInt32.max) + 5
        let current = snapshot(links: [wifi: .init(received: base + 6_000, sent: base + 4_000),
                                       ethernet: .init(received: 1_050, sent: 50)])
        let previous = [wifi: SystemCounters.Traffic(received: base, sent: base),
                        ethernet: .init(received: 50, sent: 50)]
        XCTAssertEqual(current.traffic(since: previous, seconds: 2)?.down, 3_500)
        XCTAssertEqual(current.traffic(since: previous, seconds: 2)?.up, 2_000)
        XCTAssertEqual(current.traffic(since: current.links, seconds: 1)?.down, 0)
        XCTAssertNil(current.traffic(since: previous, seconds: 0))
        XCTAssertNil(snapshot(links: [:]).traffic(since: [:], seconds: 1))
    }

    func testNetworksChangingOrResettingNeverAttributeTrafficToANewInterface() {
        let current = snapshot(links: [wifi: .init(received: 100, sent: 80)])
        XCTAssertNil(current.traffic(since: [wifi: .init(received: 101, sent: 50)], seconds: 1))
        XCTAssertNil(current.traffic(since: [SystemCounters.Link(name: wifi.name, index: 27): .init(received: 0, sent: 0)], seconds: 1))
        XCTAssertNil(current.traffic(since: [wifi: .init(received: 0, sent: 0), ethernet: .init(received: 0, sent: 0)], seconds: 1))
        XCTAssertNil(current.traffic(since: nil, seconds: 1))
    }

    func testSleepLongPausesAndClockCorrectionsResetTheSamplingInterval() {
        let start = snapshot()
        XCTAssertEqual(snapshot(uptime: 21, wall: 21).interval(since: start), 1)
        XCTAssertNil(snapshot(uptime: 20, wall: 20).interval(since: start))
        XCTAssertNil(snapshot(uptime: 21, wall: 100).interval(since: start))
        XCTAssertNil(snapshot(uptime: 40, wall: 40).interval(since: start))
        XCTAssertEqual(snapshot(uptime: 80, wall: 80).interval(since: start, maxInterval: 90), 60)
        XCTAssertNil(snapshot(uptime: 80, wall: 300).interval(since: start, maxInterval: 90))
    }

    func testDiskRatesAcrossMultiplePhysicalDrivesAndChangedDeviceIdentity() {
        let base: UInt64 = 1 << 54
        let original: [UInt64: StorageMetrics.Bytes] = [2: .init(read: base, written: 35), 6: .init(read: 100, written: 40)]
        let next: [UInt64: StorageMetrics.Bytes] = [2: .init(read: base + 89, written: 40), 6: .init(read: 111, written: 55)]
        let rates = StorageMetrics.rates(from: original, to: next, seconds: 2)
        XCTAssertEqual(rates?.read, 50)
        XCTAssertEqual(rates?.write, 10)
        XCTAssertEqual(StorageMetrics.rates(from: next, to: next, seconds: 2)?.read, 0)
        XCTAssertNil(StorageMetrics.rates(from: nil, to: original, seconds: 2))
        XCTAssertNil(StorageMetrics.rates(from: [:], to: [:], seconds: 2))
        XCTAssertNil(StorageMetrics.rates(from: next, to: original, seconds: 2))
        XCTAssertNil(StorageMetrics.rates(from: next, to: [9: .init(read: base, written: 99)], seconds: 2))
    }

    func testOnlyIdentifiedPhysicalInternalDiskTransportsQualify() {
        func included(_ location: String, _ bus: String) -> Bool {
            StorageMetrics.isInternalPhysicalBus(["Physical Interconnect Location": location, "Physical Interconnect": bus])
        }
        XCTAssertTrue(included("Internal", "Apple Fabric"))
        XCTAssertTrue(included("Internal", "SATA"))
        XCTAssertFalse(included("External", "PCI-Express"))
        XCTAssertFalse(included("File", "Virtual Interface"))
        XCTAssertFalse(included("Internal", "Virtual Interface"))
        XCTAssertFalse(included("Internal", "Secure Digital"))
        XCTAssertFalse(StorageMetrics.isInternalPhysicalBus([:]))
    }

    func testMemoryExcludesPurgeableAndCountsOnlyPhysicalCompressedPages() {
        let available = MemoryFootprint(anonymous: 200, purgeable: 50, wired: 80, compressed: 20,
                                        pageSize: 16_384, total: 100_000_000)
        XCTAssertEqual(available?.used, 250 * 16_384)
        XCTAssertEqual(available?.compressed, 20 * 16_384)
        XCTAssertEqual(available?.wired, 80 * 16_384)
        XCTAssertNil(MemoryFootprint(anonymous: 100, purgeable: 0, wired: 100, compressed: 0, pageSize: 4096, total: 100))
        XCTAssertNil(MemoryFootprint(anonymous: 100, purgeable: 0, wired: 100, compressed: 0, pageSize: .max, total: .max))
    }
}
