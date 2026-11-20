import XCTest
@testable import Wattline

final class PortOutputSensorTests: XCTestCase {
    private let controller = UUID(uuidString: "B710370E-C4B1-4878-9D1E-AF58933B3D4E")!

    private func bytes<T>(of value: T) -> [UInt8] {
        withUnsafeBytes(of: value) { Array($0) }
    }

    private func sample(current: Float?, voltage: Float = 5, presence: [UInt8] = [1, 1],
                        duplicate: Bool = false) -> Double? {
        var flags = presence.makeIterator()
        return PortOutputSensors.readings(for: [controller]) { channel, field in
            guard channel == 3 || (duplicate && channel == 4) else { return nil }
            switch field {
            case .controller: return bytes(of: controller.uuid)
            case .present: return flags.next().map { [$0] }
            case .volts: return bytes(of: voltage)
            case .amps: return current.map { bytes(of: $0) }
            }
        }[controller]
    }

    func testMeasuresOutputAndDistinguishesAnIdleRailFromAZeroReading() {
        XCTAssertEqual(sample(current: 2.5), 12.5)
        XCTAssertEqual(sample(current: 0), 0)
        XCTAssertNil(sample(current: 0, presence: [0]))
        XCTAssertNil(sample(current: 0, voltage: 0))
        XCTAssertNil(sample(current: nil))
        XCTAssertNil(sample(current: 1, presence: [1, 0]))
    }

    func testRejectsInvalidRailValuesAndAmbiguousControllers() {
        XCTAssertNil(sample(current: .nan))
        XCTAssertNil(sample(current: -1))
        XCTAssertNil(sample(current: 65_535))
        XCTAssertNil(sample(current: 1, voltage: .infinity))
        XCTAssertNil(sample(current: 1, duplicate: true))
        let unconnected = UUID()
        let map = PortOutputSensors.readings(for: [unconnected]) { _, field in
            XCTAssertEqual(field, .controller)
            return bytes(of: controller.uuid)
        }
        XCTAssertTrue(map.isEmpty)
    }
}
