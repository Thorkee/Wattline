import Foundation
import XCTest
@testable import Wattline

final class HealthChecksTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func power(_ stamp: Int, watts: Double? = nil, connected: Bool? = true,
                       internalBattery: Bool? = true, ups: Bool = false) -> PowerReading {
        PowerReading(date: epoch.addingTimeInterval(Double(stamp)), percent: nil, connected: connected,
                     charging: nil, full: nil, inputWatts: nil, systemWatts: nil, batteryWatts: watts,
                     hasInternalBattery: internalBattery, isOnUPS: ups)
    }

    private func sample(_ stamp: Int, memory: String? = nil, free: UInt64? = nil,
                        total: UInt64? = 1_000_000_000_000) -> SystemSample {
        SystemSample(date: epoch.addingTimeInterval(Double(stamp)), cpuPercent: nil, memoryUsed: nil,
                     memoryTotal: nil, swapUsed: nil, downloadBytesPerSecond: nil, uploadBytesPerSecond: nil,
                     networkInterfaces: [], memoryPressure: memory, storageTotal: total, storageAvailable: free)
    }

    func testConnectedBatteryDrainConfirmsOnceAndRearmsAfterRecoveryAndCooldown() {
        var checks = HealthChecks()
        for t in stride(from: 0, to: 180, by: 5) {
            XCTAssertTrue(checks.observe(power: power(t, watts: -8), thermal: .nominal, uptime: Double(t)).active.isEmpty)
        }
        let first = checks.observe(power: power(180, watts: -8), thermal: .nominal, uptime: 180)
        XCTAssertEqual(first.newAlerts.map(\.id), ["external-power-drain"])
        XCTAssertEqual(first.active, first.newAlerts)
        for t in stride(from: 185, through: 215, by: 5) {
            let next = checks.observe(power: power(t, watts: 0), thermal: .nominal, uptime: Double(t))
            XCTAssertTrue(next.newAlerts.isEmpty)
            XCTAssertEqual(next.active.isEmpty, t == 215)
        }
        for t in stride(from: 220, through: 410, by: 5) {
            let next = checks.observe(power: power(t, watts: -8), thermal: .nominal, uptime: Double(t))
            XCTAssertTrue(next.newAlerts.isEmpty)
            if t >= 400 { XCTAssertEqual(next.active.map(\.id), ["external-power-drain"]) }
        }
        XCTAssertTrue(checks.observe(power: power(415, watts: -8, connected: false),
                                     thermal: .nominal, uptime: 415).active.isEmpty)
        for t in stride(from: 2_200, to: 2_380, by: 5) {
            XCTAssertTrue(checks.observe(power: power(t, watts: -8), thermal: .nominal, uptime: Double(t)).newAlerts.isEmpty)
        }
        XCTAssertEqual(checks.observe(power: power(2_380, watts: -8), thermal: .nominal,
                                      uptime: 2_380).newAlerts.map(\.id), ["external-power-drain"])
    }

    func testMaintenanceMissingDesktopBatteryAndUPSAreQuiet() {
        var checks = HealthChecks()
        for t in stride(from: 0, through: 300, by: 5) {
            let inputs = [
                power(t, watts: -0.8), power(t, watts: nil), power(t, watts: -.infinity),
                power(t, watts: -12, connected: nil), power(t, watts: -12, connected: false),
                power(t, watts: -12, internalBattery: false), power(t, watts: -12, ups: true)
            ]
            for input in inputs {
                XCTAssertTrue(checks.observe(power: input, thermal: .nominal, uptime: Double(t)).active.isEmpty)
            }
        }
    }

    func testThermalPressureUsesIndependentDwellAndIgnoresSleepAndClockJumps() {
        var checks = HealthChecks()
        for t in stride(from: 0, through: 80, by: 5) {
            XCTAssertTrue(checks.observe(power: power(t), thermal: .serious, uptime: Double(t)).newAlerts.isEmpty)
        }
        XCTAssertTrue(checks.observe(power: power(90), thermal: .serious, uptime: 90, afterSleep: true).active.isEmpty)
        XCTAssertTrue(checks.observe(power: power(95), thermal: .critical, uptime: 95).active.isEmpty)
        XCTAssertTrue(checks.observe(power: power(100), thermal: .critical, uptime: 100).active.isEmpty)
        XCTAssertTrue(checks.observe(power: power(1_000), thermal: .critical, uptime: 105).active.isEmpty)
        XCTAssertTrue(checks.observe(power: power(1_010), thermal: .critical, uptime: 115).active.isEmpty)
        let critical = checks.observe(power: power(1_015), thermal: .critical, uptime: 120)
        XCTAssertEqual(critical.newAlerts.map(\.id), ["thermal-pressure"])
        XCTAssertEqual(critical.active.first?.severity, .critical)
        XCTAssertTrue(checks.observe(power: power(1_050), thermal: .critical, uptime: 155).active.isEmpty)
    }

    func testOnlyCriticalMemoryAndLowAbsoluteAndRelativeDiskSpaceAlert() {
        var checks = HealthChecks()
        for t in [0, 60] {
            XCTAssertTrue(checks.observe(system: sample(t, memory: "Critical", free: 3_000_000_000),
                                         uptime: Double(t)).active.isEmpty)
        }
        let low = checks.observe(system: sample(120, memory: "Critical", free: 3_000_000_000), uptime: 120)
        XCTAssertEqual(low.active.map(\.id), ["memory-pressure", "startup-disk-space"])
        XCTAssertEqual(low.newAlerts.count, 2)
        let recovered = checks.observe(system: sample(180), uptime: 180)
        XCTAssertTrue(recovered.active.isEmpty)

        for t in [240, 300, 360] {
            XCTAssertTrue(checks.observe(system: sample(t, memory: "Elevated", free: 4_000_000_000,
                                                        total: 32_000_000_000), uptime: Double(t)).active.isEmpty)
        }
    }

    func testSystemIssuesExpireWhenOnlyPowerSamplesKeepArriving() {
        var checks = HealthChecks()
        for t in [0, 60, 120] {
            _ = checks.observe(system: sample(t, memory: "Critical"), uptime: Double(t))
        }
        let recent = checks.observe(power: power(125), thermal: .nominal, uptime: 125)
        XCTAssertEqual(recent.active.map(\.id), ["memory-pressure"])
        let expired = checks.observe(power: power(245), thermal: .nominal, uptime: 245)
        XCTAssertTrue(expired.active.isEmpty)
    }
}
