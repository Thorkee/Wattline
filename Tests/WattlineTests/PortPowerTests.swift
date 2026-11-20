import XCTest
@testable import Wattline

final class PortPowerTests: XCTestCase {
    private func port(_ id: UInt64, type: String = "USB-C", number: Any = 1, connected: Any = true,
                      builtIn: Bool = true, winning: [[String: Any]] = [],
                      transports: [String] = [], sources: [[String: Any]] = [], socket: Int? = nil,
                      controller: UUID? = nil, connection: UUID? = nil) -> PortPower.Observation {
        var properties: [String: Any] = [
            "BuiltIn": builtIn, "PortTypeDescription": type, "PortNumber": number,
            "ConnectionActive": connected, "TransportsActive": transports
        ]
        properties["ConnectionUUID"] = connection?.uuidString
        return PortPower.Observation(id: id, properties: properties, sources: sources + winning.map { ["WinningPowerSourceOption": $0] },
                                     controllerUUID: controller, socketIndex: socket)
    }

    func testAdvancingFirmwareOutputOnTheSameAttachmentExpiresWhenFrozen() {
        var history = PortPower.OutputHistory()
        let original = port(8, number: 3, socket: 3, connection: UUID())
        let replacement = port(8, number: 3, socket: 3, connection: UUID())
        func read(_ p: PortPower.Observation, _ count: Int, _ now: TimeInterval) -> Double? {
            let row = ["PortIndex": 3, "Watts": 6740, "AdapterVoltage": 5000, "Current": 1348, "AccumulatorCount": count]
            return history.resolve(ports: [p], batteryRows: [row], sensors: [:], now: now)[8]
        }
        XCTAssertNil(read(original, 100, 0))
        XCTAssertEqual(read(original, 105, 5), 6.74)
        XCTAssertEqual(read(original, 105, 10), 6.74)
        XCTAssertNil(read(original, 105, 21))
        XCTAssertEqual(read(original, 110, 25), 6.74)
        XCTAssertNil(read(replacement, 111, 30))
        XCTAssertEqual(read(replacement, 115, 35), 6.74)
        XCTAssertNil(read(replacement, 3, 40))
        XCTAssertNil(read(replacement, 100, 105))
    }

    func testSensorOutputRequiresUniqueControllerAndOutboundConnection() {
        var history = PortPower.OutputHistory()
        let controller = UUID()
        let socket = port(8, controller: controller)
        func resolve(_ rows: [PortPower.Observation], _ watts: Double = 3.4) -> [UInt64: Double] {
            history.resolve(ports: rows, batteryRows: [], sensors: [controller: watts], now: 0)
        }
        XCTAssertEqual(resolve([socket]), [8: 3.4])
        XCTAssertEqual(resolve([socket], 0), [8: 0])
        XCTAssertTrue(resolve([socket], .nan).isEmpty)
        XCTAssertTrue(resolve([socket, port(9, number: 2, controller: controller)]).isEmpty)
        XCTAssertTrue(resolve([port(8, type: "MagSafe 3", controller: controller)]).isEmpty)
        XCTAssertTrue(resolve([port(8, connected: false, controller: controller)]).isEmpty)
        XCTAssertTrue(resolve([port(8, connected: "true", controller: controller)]).isEmpty)
        XCTAssertTrue(resolve([port(8, winning: [[:]], controller: controller)]).isEmpty)
        let standby: [String: Any] = ["PowerSourceName": "USB-PD", "PowerSourceOptions": [["Max Power (mW)": 60_000]]]
        XCTAssertTrue(resolve([port(8, sources: [standby], controller: controller)]).isEmpty)
    }

    func testFirmwareOutputRejectsAmbiguousPortsAndUnmeasuredOrMismatchedFrames() {
        let connection = UUID()
        let socket = port(8, number: 3, socket: 3, connection: connection)
        let row: [String: Any] = ["PortIndex": 3, "Watts": 6740, "AdapterVoltage": 5000, "Current": 1348]
        func readings(_ ports: [PortPower.Observation], _ frames: [[String: Any]]) -> [UInt64: Double] {
            var history = PortPower.OutputHistory()
            func samples(_ count: Int) -> [[String: Any]] {
                frames.map { $0.merging(["AccumulatorCount": count]) { value, _ in value } }
            }
            _ = history.resolve(ports: ports, batteryRows: samples(1), sensors: [:], now: 1)
            return history.resolve(ports: ports, batteryRows: samples(2), sensors: [:], now: 2)
        }
        XCTAssertEqual(readings([socket], [row]), [8: 6.74])
        XCTAssertTrue(readings([socket, port(9, number: 3, socket: 4)], [row]).isEmpty)
        XCTAssertTrue(readings([port(8, number: 2, socket: 3, connection: connection)], [row]).isEmpty)
        XCTAssertTrue(readings([port(8, number: 3, socket: 3)], [row]).isEmpty)
        XCTAssertTrue(readings([socket], [row, row]).isEmpty)
        for changes: [String: Any] in [["PortIndex": true], ["Current": 0], ["Current": 200], ["Watts": -20],
                                       ["Watts": true], ["AdapterVoltage": UInt16.max], ["AccumulatorCount": 65_535]] {
            XCTAssertTrue(readings([socket], [row.merging(changes) { _, new in new }]).isEmpty)
        }
        XCTAssertTrue(readings([socket], [["PortIndex": 3, "ConfiguredVoltage": 5000, "ConfiguredCurrent": 3000]]).isEmpty)
    }

    func testOnlyConnectedFixedPDProfilesExposeOfferedPower() {
        let fixed = "IOPortFeaturePowerSourceOptionFixed"
        func profile(_ type: String, _ power: Any, _ volts: Int, _ amps: Int) -> [String: Any] {
            ["Class": type, "Max Power (mW)": power, "Voltage (mV)": volts, "Max Current (mA)": amps]
        }
        let pd: [String: Any] = ["PowerSourceName": "USB-PD", "PowerSourceOptions": NSSet(array: [
            profile(fixed, 15_000, 5_000, 3_000), profile(fixed, 60_000, 20_000, 3_000),
            profile(fixed, UInt32.max, 20_000, 3_000), profile(fixed, 200_000, 15_000, 3_000),
            profile("Variable", 100_000, 20_000, 5_000), "unreadable"
        ] as [Any])]
        let other = ["PowerSourceName": "Brick ID", "PowerSourceOptions": [profile(fixed, 100_000, 20_000, 5_000)]] as [String: Any]
        let observations = [port(1, sources: [other, pd]), port(2, number: 2, sources: [other]),
                            port(3, number: 3, connected: false, sources: [pd]),
                            port(4, number: 4, sources: [pd, pd])]
        let rows = PortPower.decode(observations, adapterWatts: 60)
        XCTAssertEqual(rows.first { $0.id == 1 }?.offeredWatts, 60)
        XCTAssertTrue(rows.filter { $0.id != 1 }.allSatisfy { $0.offeredWatts == nil })
        XCTAssertTrue(rows.allSatisfy { $0.limitWatts == nil && !$0.isPowerInput })
    }

    func testSelectsOnlyCorroboratedUniqueInputAndActiveDataLinks() {
        let ports = [port(25, number: 2, connected: false, transports: ["USB2"]),
                     port(10, winning: [["Max Power (mW)": 60_000]],
                          transports: ["CC", "USB2", "DisplayPort", "USB2", "Unknown"]),
                     port(30, type: "MagSafe 3", connected: false),
                     port(45, builtIn: false, winning: [["Max Power (mW)": 60_000]])]
        let result = PortPower.decode(ports, adapterWatts: 60)
        XCTAssertEqual(result.map(\.id), [10, 30, 25])
        XCTAssertEqual(result.first?.label, "USB-C 1")
        XCTAssertEqual(result.first?.isPowerInput, true)
        XCTAssertEqual(result.first?.limitWatts, 60)
        XCTAssertEqual(result.first?.transports, ["USB 2", "DisplayPort"])
        XCTAssertTrue(result.dropFirst().allSatisfy { $0.transports.isEmpty && $0.limitWatts == nil })
    }

    func testMultipleOrUnverifiedContractDoesNotIdentifyTheSystemInput() {
        let selected = port(2, winning: [["Max Power (mW)": 60_000]])
        for watts: Double? in [nil, 45, .nan] {
            let result = PortPower.decode([selected], adapterWatts: watts)
            XCTAssertEqual(result.first?.isPowerInput, false)
            XCTAssertEqual(result.first?.limitWatts, 60)
        }
        for other in [port(3, number: 2, winning: [["Max Power (mW)": 60_000]]),
                      port(3, number: 2, connected: "?", winning: [[:]])] {
            XCTAssertTrue(PortPower.decode([selected, other], adapterWatts: 60).allSatisfy { !$0.isPowerInput })
        }
    }

    func testUnsupportedMalformedAndDisconnectedPortDataRemainUnavailable() {
        XCTAssertTrue(PortPower.decode([], adapterWatts: 100).isEmpty)
        XCTAssertTrue(PortPower.decode([port(1, type: "  ")], adapterWatts: 60).isEmpty)
        let rows = [
            port(1, number: "2", connected: true, winning: [["Max Power (mW)": true]]),
            port(2, number: 2, connected: false, winning: [["Max Power (mW)": 60_000]]),
            port(3, number: 3, connected: "false", winning: [["Max Power (mW)": -1]]),
            port(4, number: 4, winning: [["Max Power (mW)": Double.infinity]]),
            port(5, type: "SD Card", winning: []),
            port(6, number: 6, winning: [["Max Power (mW)": NSNumber(value: UInt32.max)]])
        ]
        let result = PortPower.decode(rows, adapterWatts: 60)
        XCTAssertEqual(result.count, rows.count)
        XCTAssertTrue(result.allSatisfy { $0.limitWatts == nil && !$0.isPowerInput })
        XCTAssertEqual(result.first { $0.id == 1 }?.label, "USB-C")
        XCTAssertNil(result.first { $0.id == 3 }?.connected)
    }

    func testRepeatedTypesUseReportedNumbersAndSortNumerically() {
        let rows = [port(7, type: "HDMI", number: 10), port(6, type: "HDMI", number: 2)]
        let result = PortPower.decode(rows, adapterWatts: nil)
        XCTAssertEqual(result.map(\.label), ["HDMI 2", "HDMI 10"])
        XCTAssertEqual(result.map(\.id), [6, 7])
    }
}
