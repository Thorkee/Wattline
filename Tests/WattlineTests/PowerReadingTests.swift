import Foundation
import XCTest
@testable import Wattline

final class PowerReadingTests: XCTestCase {
    func testChargerSwitchUsesCorroboratedTerminalDirection() throws {
        var registry: [String: Any] = [
            "ExternalConnected": true, "IsCharging": true, "Voltage": 12_517, "InstantAmperage": 2_674,
            "PowerTelemetryData": ["SystemPowerIn": 82_195, "SystemLoad": 110_996, "BatteryPower": -28_801]
        ]
        let charging = PowerReading.decode(registry: registry)
        let terminal = 12.517 * 2.674
        XCTAssertEqual(try XCTUnwrap(charging.batteryWatts), terminal, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(charging.systemWatts), 82.195 - terminal, accuracy: 0.001)
        XCTAssertEqual(charging.state, .charging)
        registry["IsCharging"] = false
        let uncertain = PowerReading.decode(registry: registry)
        XCTAssertNil(uncertain.batteryWatts)
        XCTAssertNil(uncertain.systemWatts)
        XCTAssertEqual(uncertain.state, .unknown)
    }

    func testZeroFrameIsAGapRatherThanZeroWatts() {
        let reading = PowerReading.decode(registry: [
            "ExternalConnected": true, "PowerTelemetryData": ["SystemLoad": 0, "SystemPowerIn": 0, "BatteryPower": 0]
        ])
        XCTAssertNil(reading.systemWatts)
        XCTAssertNil(reading.inputWatts)
        XCTAssertNil(reading.batteryWatts)
    }

    func testZeroLoadCanBeRecoveredFromMeasuredInputAndBatteryCurrent() {
        let reading = PowerReading.decode(registry: [
            "ExternalConnected": true, "Voltage": 11_000, "InstantAmperage": 1_000,
            "PowerTelemetryData": ["SystemLoad": 0, "SystemPowerIn": 0, "BatteryPower": 0,
                                   "SystemVoltageIn": 20_000, "SystemCurrentIn": 2_000]
        ])
        XCTAssertEqual(reading.inputWatts, 40)
        XCTAssertEqual(reading.batteryWatts, 11)
        XCTAssertEqual(reading.systemWatts, 29)
    }

    func testZeroNetResultIsUnavailableAndRealZeroBatteryFlowIsPreserved() {
        func reading(battery: Int) -> PowerReading {
            PowerReading.decode(registry: ["PowerTelemetryData": [
                "SystemLoad": 0, "SystemPowerIn": 12_000, "BatteryPower": battery
            ]])
        }
        XCTAssertNil(reading(battery: 12_000).systemWatts)
        XCTAssertEqual(reading(battery: 0).batteryWatts, 0)
        XCTAssertEqual(reading(battery: 0).systemWatts, 12)
    }

    func testDrainWinsOverChargingFlagAndSeparatesAvailableFromDeliveredPower() {
        let sample = PowerReading.decode(registry: [
            "ExternalConnected": true, "IsCharging": true,
            "CurrentCapacity": 12, "MaxCapacity": 100,
            "AdapterDetails": ["Watts": 100],
            "PowerTelemetryData": [
                "BatteryPower": NSNumber(value: UInt64(bitPattern: -32_544)),
                "SystemPowerIn": 81_374, "SystemLoad": 113_918
            ]
        ])
        XCTAssertEqual(sample.percent, 12)
        XCTAssertEqual(sample.adapterWatts, 100)
        XCTAssertEqual(sample.inputWatts, 81.374)
        XCTAssertEqual(sample.systemWatts, 113.918)
        XCTAssertEqual(sample.batteryWatts, -32.544)
        XCTAssertEqual(sample.state, .pluggedDraining)
    }

    func testConnectedWithZeroInputCanDrain() {
        let sample = PowerReading.decode(registry: [
            "ExternalConnected": true, "IsCharging": false,
            "PowerTelemetryData": ["BatteryPower": -24_666, "SystemPowerIn": 0]
        ])
        XCTAssertEqual(sample.inputWatts, 0)
        XCTAssertEqual(sample.state, .pluggedDraining)
    }

    func testStuckZeroBatteryChannelRequiresLoadBalanceAndTerminalAgreement() {
        func reading(input: Int, current: Int) -> PowerReading {
            PowerReading.decode(registry: [
                "ExternalConnected": true, "IsCharging": false, "Voltage": 12_000, "InstantAmperage": current,
                "PowerTelemetryData": ["BatteryPower": 0, "SystemPowerIn": input, "SystemLoad": 24_000]
            ])
        }
        let draining = reading(input: 0, current: -2_000)
        XCTAssertEqual(draining.state, .pluggedDraining)
        XCTAssertEqual(draining.batteryWatts, -24)
        XCTAssertEqual(draining.systemWatts, 24)
        XCTAssertEqual(reading(input: 48_000, current: 2_000).state, .charging)
        // Actual zero flow: the charger supplies the entire load. An old
        // terminal sample alone cannot turn that into a drain or charge.
        XCTAssertEqual(reading(input: 24_000, current: -2_000).batteryWatts, 0)
        XCTAssertEqual(reading(input: 48_000, current: -2_000).batteryWatts, 0)
    }

    func testNegativeSystemLoadUsesTerminalCurrentToRecoverPluggedInDrain() throws {
        let sample = PowerReading.decode(registry: [
            "ExternalConnected": true, "IsCharging": true, "Voltage": 10_721, "InstantAmperage": -3_522,
            "PowerTelemetryData": ["BatteryPower": 29_703, "SystemPowerIn": 13_286, "SystemLoad": -16_417]
        ])
        XCTAssertEqual(try XCTUnwrap(sample.batteryWatts), -37.759362, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sample.systemWatts), 51.045362, accuracy: 0.000001)
        XCTAssertEqual(sample.state, .pluggedDraining)
    }

    func testImpossibleChargeWithoutTrustworthyTerminalMeasurementsIsUnknown() {
        for current in [nil, 3_000] as [Int?] {
            var registry: [String: Any] = [
                "ExternalConnected": true, "IsCharging": true, "Voltage": 11_000,
                "PowerTelemetryData": ["BatteryPower": 31_574, "SystemPowerIn": 13_296, "SystemLoad": -18_278]
            ]
            registry["InstantAmperage"] = current
            let sample = PowerReading.decode(registry: registry)
            XCTAssertNil(sample.batteryWatts)
            XCTAssertNil(sample.systemWatts)
            XCTAssertEqual(sample.inputWatts, 13.296)
            XCTAssertEqual(sample.state, .unknown)
        }
    }

    func testMeasuredChargeWinsOverFlagAndNoiseIsTreatedAsHolding() {
        func sample(_ milliwatts: Int, full: Bool = false) -> PowerReading {
            PowerReading.decode(registry: [
                "ExternalConnected": true, "IsCharging": false, "FullyCharged": full,
                "PowerTelemetryData": ["BatteryPower": milliwatts]
            ])
        }
        XCTAssertEqual(sample(21_536).state, .charging)
        XCTAssertEqual(sample(-35).state, .holding)
        XCTAssertEqual(sample(0, full: true).state, .full)
    }

    func testOlderBatteryUsesTerminalCurrentAndCapacityRatio() {
        let sample = PowerReading.decode(registry: [
            "ExternalConnected": false, "CurrentCapacity": 1_500, "MaxCapacity": 5_000,
            "Voltage": 12_000, "Amperage": NSNumber(value: UInt32(bitPattern: -2_000)),
            "AdapterDetails": ["Watts": 70]
        ])
        XCTAssertEqual(sample.percent, 30)
        XCTAssertEqual(sample.batteryWatts, -24)
        XCTAssertEqual(sample.state, .onBattery)
        XCTAssertEqual(sample.inputWatts, 0)
        XCTAssertNil(sample.adapterWatts)
        XCTAssertEqual(sample.systemWatts, 24)
    }

    func testMissingSensorsUsePublicSourceWithoutInventingWattage() {
        let sample = PowerReading.decode(registry: [:], source: [
            "Power Source State": "AC Power", "Current Capacity": 83, "Max Capacity": 100,
            "Is Charging": false
        ])
        XCTAssertEqual(sample.percent, 83)
        XCTAssertEqual(sample.state, .holding)
        XCTAssertNil(sample.inputWatts)
        XCTAssertNil(sample.batteryWatts)
        XCTAssertNil(sample.systemWatts)
        XCTAssertNil(sample.adapterWatts)
    }

    func testPublicBatteryCurrentAndVoltageRecoverAnUnpluggedMacDraw() {
        let sample = PowerReading.decode(registry: [:], records: [[
            "Type": "InternalBattery", "Power Source State": "Battery Power", "Current": -2_000, "Voltage": 12_000
        ]], provider: "Battery Power", inventoryComplete: true)
        XCTAssertEqual(sample.systemWatts, 24)
        XCTAssertEqual(sample.batteryWatts, -24)
        XCTAssertEqual(sample.state, .onBattery)
    }

    func testUnavailableDataDoesNotImplyTheBatteryIsEmptyOrHolding() {
        let sample = PowerReading.decode(registry: [
            "CurrentCapacity": 50, "MaxCapacity": 0,
            "PowerTelemetryData": ["BatteryPower": true, "SystemLoad": -1]
        ])
        XCTAssertNil(sample.percent)
        XCTAssertNil(sample.systemWatts)
        XCTAssertNil(sample.batteryWatts)
        XCTAssertNil(sample.connected)
        XCTAssertEqual(sample.state, .unknown)
    }

    func testConfirmedACDesktopAndIncompleteSourceInventory() {
        let desktop = PowerReading.decode(registry: [:], records: [], provider: "AC Power", inventoryComplete: true)
        XCTAssertEqual(desktop.state, .acPower)
        XCTAssertEqual(desktop.hasInternalBattery, false)
        XCTAssertNil(desktop.percent)
        XCTAssertNil(desktop.adapterWatts)
        XCTAssertNil(desktop.systemWatts)
        let unavailable = PowerReading.decode(registry: [:], records: [], provider: "AC Power", inventoryComplete: false)
        XCTAssertEqual(unavailable.state, .unknown)
        XCTAssertNil(unavailable.hasInternalBattery)
    }

    func testUPSAndAccessoriesAreNotAnInternalBattery() {
        let records: [[String: Any]] = [
            ["Type": "UPS", "Is Present": true, "Max Capacity": 100, "Current Capacity": 92],
            ["Type": "Accessory", "Is Present": true, "Current Capacity": 80],
            ["Type": "InternalBattery", "Is Present": false, "Current Capacity": 34]
        ]
        let ups = PowerReading.decode(registry: [:], records: records, provider: "UPS Power", inventoryComplete: true)
        XCTAssertEqual(ups.state, .ups)
        XCTAssertEqual(ups.hasInternalBattery, false)
        XCTAssertNil(ups.percent)
        XCTAssertNil(ups.inputWatts)
        XCTAssertNil(ups.batteryWatts)
        let wall = PowerReading.decode(registry: [:], records: records, provider: "AC Power", inventoryComplete: true)
        XCTAssertEqual(wall.state, .acPower)
    }

    func testMacBookPoweredByUPSReportsInternalBatteryCapacity() {
        let records: [[String: Any]] = [
            ["Type": "UPS", "Max Capacity": 100, "Current Capacity": 92],
            ["Type": "InternalBattery", "Is Present": true, "Current Capacity": 44, "Max Capacity": 100]
        ]
        let reading = PowerReading.decode(registry: [:], records: records, provider: "UPS Power", inventoryComplete: true)
        XCTAssertEqual(reading.state, .ups)
        XCTAssertEqual(reading.hasInternalBattery, true)
        XCTAssertEqual(reading.percent, 44)
    }

    func testAStaleOrFutureDriverTimestampUsesPublicSourceAndDropsOldWatts() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        for seconds in [-3_600.0, 3_600.0] {
            let sample = PowerReading.decode(registry: [
                "ExternalConnected": true, "IsCharging": true, "CurrentCapacity": 6, "MaxCapacity": 100,
                "PowerTelemetryData": ["BatteryPower": 5_500, "SystemLoad": 42_000],
                "UpdateTime": now.timeIntervalSince1970 + seconds
            ], source: ["Power Source State": "Battery Power", "Current Capacity": 54, "Max Capacity": 100], date: now)
            XCTAssertEqual(sample.percent, 54)
            XCTAssertEqual(sample.state, .onBattery)
            XCTAssertNil(sample.batteryWatts)
            XCTAssertNil(sample.systemWatts)
        }
        let legacy = PowerReading.decode(registry: ["UpdateTime": 12_345, "PowerTelemetryData": ["SystemLoad": 27_000]], date: now)
        XCTAssertEqual(legacy.systemWatts, 27)
    }

    func testRawCapacityAndMissingBatterySensorSentinels() {
        let registry: [String: Any] = [
            "CurrentCapacity": 65_535, "MaxCapacity": 65_535, "AppleRawCurrentCapacity": 1_500,
            "AppleRawMaxCapacity": 6_000, "Voltage": 65_535, "InstantAmperage": -300,
            "PowerTelemetryData": ["SystemLoad": Double.infinity], "AdapterDetails": ["Watts": 0]
        ]
        let sample = PowerReading.decode(registry: registry)
        XCTAssertEqual(sample.percent, 25)
        XCTAssertNil(sample.adapterWatts)
        XCTAssertNil(sample.batteryWatts)
        XCTAssertNil(sample.systemWatts)
    }

    func testUnplugDiscardsPriorAdapterSampleAndUsesTerminalDischarge() {
        let sample = PowerReading.decode(registry: [
            "ExternalConnected": false, "Voltage": 12_000, "InstantAmperage": -1_000,
            "PowerTelemetryData": ["SystemPowerIn": 50_000, "BatteryPower": 0, "SystemLoad": 50_000]
        ])
        XCTAssertEqual(sample.state, .onBattery)
        XCTAssertEqual(sample.inputWatts, 0)
        XCTAssertEqual(sample.systemWatts, 12)
        XCTAssertEqual(sample.batteryWatts, -12)
    }
}
