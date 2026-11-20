import Foundation
import IOKit
import IOKit.ps

struct PortPower: Identifiable, Sendable {
    let id: UInt64
    let label: String
    let connected: Bool?
    let transports: [String]
    let limitWatts: Double?
    let isPowerInput: Bool
    var offeredWatts: Double? = nil
    var outputWatts: Double? = nil

    /// Registry IDs identify physical built-in port services for the lifetime of this boot.
    struct Observation {
        let id: UInt64
        let properties: [String: Any]
        let sources: [[String: Any]]
        var controllerUUID: UUID? = nil
        var socketIndex: Int? = nil
        var winningOptions: [[String: Any]] {
            sources.compactMap { source in
                source["WinningPowerSourceOption"].map { $0 as? [String: Any] ?? [:] }
            }
        }

        var maySupplyPower: Bool {
            guard properties["PortTypeDescription"] as? String == "USB-C",
                  boolean(properties["ConnectionActive"]) == true, winningOptions.isEmpty else { return false }
            return !sources.contains { source in
                guard let options = source["PowerSourceOptions"] else { return false }
                if let set = options as? NSSet { return set.count > 0 }
                if let array = options as? [Any] { return !array.isEmpty }
                return true
            }
        }
    }

    actor Reader {
        private var outputs = OutputHistory()

        func read() -> [PortPower] { PortPower.read(outputs: &outputs) }
    }

    private static func read(outputs: inout OutputHistory) -> [PortPower] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOPort"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var observations: [Observation] = []
        while case let port = IOIteratorNext(iterator), port != IO_OBJECT_NULL {
            defer { IOObjectRelease(port) }
            guard let properties = properties(of: port), boolean(properties["BuiltIn"]) == true else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(port, &id) == KERN_SUCCESS else { continue }
            let sources = boolean(properties["ConnectionActive"]) == false ? [] : powerSources(of: port)
            var entry = Observation(id: id, properties: properties, sources: sources)
            if properties["PortTypeDescription"] as? String == "USB-C" {
                // PowerOutDetails uses the USB-C controller's physical IOService
                // location. Accept it only when the port itself confirms that number.
                if IOObjectConformsTo(port, "IOAccessoryManager") != 0 {
                    var location = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
                    if IORegistryEntryGetLocationInPlane(port, kIOServicePlane, &location) == KERN_SUCCESS,
                       let socket = Int(String(cString: location), radix: 16), socket > 0 {
                        entry.socketIndex = socket
                    }
                }
                if boolean(properties["ConnectionActive"]) == true {
                    entry.controllerUUID = PortOutputSensors.controllerUUID(for: port)
                }
            }
            observations.append(entry)
        }
        guard IOIteratorIsValid(iterator) != 0 else { return [] }
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        let candidates = observations.filter(\.maySupplyPower)
        let controllers = Set(candidates.compactMap(\.controllerUUID))
        let sensors = controllers.isEmpty ? [:] : PortOutputSensors.read(controllers: controllers)
        var batteryRows: [[String: Any]] = []
        if candidates.contains(where: { $0.socketIndex != nil }) {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                batteryRows = IORegistryEntryCreateCFProperty(service, "PowerOutDetails" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] ?? []
            }
        }
        var measured = outputs.resolve(ports: observations, batteryRows: batteryRows, sensors: sensors,
                                       now: ProcessInfo.processInfo.systemUptime)
        // Sampling the controller and battery takes separate IOKit calls. If the
        // cable or power role changed in between, discard this connector's sample.
        for observation in candidates where measured[observation.id] != nil {
            if !sameOutputConnection(observation) { measured.removeValue(forKey: observation.id) }
        }
        return decode(observations, adapterWatts: positive(adapter?[kIOPSPowerAdapterWattsKey]), outputs: measured)
    }

    static func decode(_ observations: [Observation], adapterWatts: Double?, outputs: [UInt64: Double] = [:]) -> [PortPower] {
        let ports = observations.filter { boolean($0.properties["BuiltIn"]) == true }
        let winners = ports.filter { boolean($0.properties["ConnectionActive"]) != false && !$0.winningOptions.isEmpty }
        return ports.compactMap { entry -> PortPower? in
            guard let rawType = entry.properties["PortTypeDescription"] as? String else { return nil }
            let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !type.isEmpty else { return nil }
            let connected = boolean(entry.properties["ConnectionActive"])
            let numbered = type == "USB-C" || type == "USB-A" || ports.contains {
                $0.id != entry.id && ($0.properties["PortTypeDescription"] as? String) == rawType
            }
            let number = positive(entry.properties["PortNumber"])
            let label: String
            if numbered, let number, number == number.rounded(), number < Double(Int32.max) {
                label = type + " " + String(Int(number))
            } else {
                label = type
            }
            let winning = entry.winningOptions
            let limit = connected == true && winning.count == 1
                ? positive(winning[0]["Max Power (mW)"]).map { $0 / 1_000 } : nil
            // The selected option is an input ceiling. The external adapter report uses whole watts.
            let matched: Bool
            if winners.count == 1, let limit, let adapterWatts {
                matched = abs(limit - adapterWatts) < 1
            } else {
                matched = false
            }
            let active = entry.properties["TransportsActive"] as? [String] ?? []
            return PortPower(id: entry.id, label: label, connected: connected,
                             transports: connected == true ? transportNames(active) : [],
                             limitWatts: limit, isPowerInput: matched,
                             offeredWatts: connected == true ? highestFixedPDOffer(in: entry.sources) : nil,
                             outputWatts: outputs[entry.id])
        }.sorted { lhs, rhs in
            if lhs.isPowerInput != rhs.isPowerInput { return lhs.isPowerInput }
            if (lhs.connected == true) != (rhs.connected == true) { return lhs.connected == true }
            let order = lhs.label.localizedStandardCompare(rhs.label)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    struct OutputHistory {
        private struct FirmwareSample {
            let connection: UUID
            let count: Int
            let seenAt: TimeInterval
            let advancedAt: TimeInterval?
        }
        private var previous: [UInt64: FirmwareSample] = [:]

        mutating func resolve(ports: [Observation], batteryRows: [[String: Any]], sensors: [UUID: Double],
                              now: TimeInterval) -> [UInt64: Double] {
            let usb = ports.filter {
                boolean($0.properties["BuiltIn"]) == true && $0.properties["PortTypeDescription"] as? String == "USB-C"
            }
            let rows = Dictionary(grouping: batteryRows) { positive($0["PortIndex"]) }
            var next: [UInt64: FirmwareSample] = [:]
            var readings: [UInt64: Double] = [:]
            for port in usb where port.maySupplyPower {
                if let controller = port.controllerUUID, let watts = sensors[controller],
                   watts.isFinite, watts >= 0, usb.filter({ $0.controllerUUID == controller }).count == 1 {
                    readings[port.id] = watts
                    continue
                }
                guard let socket = port.socketIndex, positive(port.properties["PortNumber"]) == Double(socket),
                      usb.filter({ $0.socketIndex == socket || positive($0.properties["PortNumber"]) == Double(socket) }).count == 1,
                      let matching = rows[Double(socket)], matching.count == 1, let row = matching.first,
                      let watts = Self.batteryOutput(row), let counter = positive(row["AccumulatorCount"]),
                      counter < Double(UInt16.max), counter.rounded() == counter,
                      let token = port.properties["ConnectionUUID"] as? String, let connection = UUID(uuidString: token) else { continue }

                // Firmware can hold the same frame while the driver updates other
                // battery properties. Require progress on this attachment, and
                // expire a frozen frame after three five-second polling intervals.
                let count = Int(counter)
                var advancedAt: TimeInterval?
                if let old = previous[port.id], old.connection == connection, now >= old.seenAt,
                   now - old.seenAt <= 15, count >= old.count {
                    advancedAt = count > old.count ? now : old.advancedAt
                }
                next[port.id] = FirmwareSample(connection: connection, count: count, seenAt: now, advancedAt: advancedAt)
                if let advancedAt, now - advancedAt <= 15 { readings[port.id] = watts }
            }
            previous = next
            return readings
        }

        private static func batteryOutput(_ row: [String: Any]) -> Double? {
            // "Watts" is measured milliwatts in PowerOutDetails. Cross-check
            // against measured mV and mA; configured PD values are only limits.
            guard let mw = positive(row["Watts"]), mw <= 260_000,
                  let mv = positive(row["AdapterVoltage"]), mv <= 53_000,
                  let ma = positive(row["Current"]), ma <= 6_000,
                  abs(mw - mv * ma / 1_000) <= max(30, mw * 0.08) else { return nil }
            return mw / 1_000
        }
    }

    private static func highestFixedPDOffer(in sources: [[String: Any]]) -> Double? {
        let pdSources = sources.filter { $0["PowerSourceName"] as? String == "USB-PD" }
        guard pdSources.count == 1 else { return nil }
        let rawOptions = pdSources[0]["PowerSourceOptions"]
        guard let options = (rawOptions as? NSSet)?.allObjects ?? rawOptions as? [Any] else { return nil }
        return options.compactMap { raw -> Double? in
            guard let option = raw as? [String: Any],
                  option["Class"] as? String == "IOPortFeaturePowerSourceOptionFixed",
                  let mw = positive(option["Max Power (mW)"]), let mv = positive(option["Voltage (mV)"]),
                  let ma = positive(option["Max Current (mA)"]), abs(mw - mv * ma / 1_000) <= 1 else { return nil }
            return mw / 1_000
        }.max()
    }

    private static func sameOutputConnection(_ original: Observation) -> Bool {
        let port = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(original.id))
        guard port != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(port) }
        guard let current = properties(of: port),
              original.properties["ConnectionUUID"] as? String == current["ConnectionUUID"] as? String else { return false }
        return Observation(id: original.id, properties: current, sources: powerSources(of: port)).maySupplyPower
    }

    private static func powerSources(of port: io_registry_entry_t) -> [[String: Any]] {
        var sources: [[String: Any]] = []
        visitChildren(of: port, conformingTo: "IOPortFeaturePowerIn") { feature in
            visitChildren(of: feature, conformingTo: "IOPortFeaturePowerSource") { source in
                if let details = properties(of: source) { sources.append(details) }
            }
        }
        return sources
    }

    private static func visitChildren(of entry: io_registry_entry_t, conformingTo kind: String,
                                      visit: (io_registry_entry_t) -> Void) {
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, kind) != 0 { visit(child) }
        }
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    private static func transportNames(_ active: [String]) -> [String] {
        let names = ["USB2": "USB 2", "USB3": "USB 3", "USB4": "USB4", "DisplayPort": "DisplayPort",
                     "Thunderbolt": "Thunderbolt", "HDMI": "HDMI", "SD": "SD"]
        var result: [String] = []
        for key in active {
            if let name = names[key], !result.contains(name) { result.append(name) }
        }
        return result
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func positive(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue > 0, number.doubleValue < Double(UInt32.max) else { return nil }
        return number.doubleValue
    }
}
