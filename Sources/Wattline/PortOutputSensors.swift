import Foundation
import IOKit

/// Optional output-rail readings for the physical USB-C connectors on some Macs.
/// Every read is scoped to a visible Ports refresh, with no persistent driver connection.
enum PortOutputSensors {
    static func controllerUUID(for port: io_registry_entry_t) -> UUID? {
        func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }

        guard property(port, "BuiltIn") as? Bool == true,
              property(port, "ConnectionActive") as? Bool == true,
              property(port, "PortTypeDescription") as? String == "USB-C",
              IOObjectRetain(port) == KERN_SUCCESS else { return nil }
        var entry = port
        defer { IOObjectRelease(entry) }
        // ConnectionUUID identifies the current attachment. The SMC instead uses
        // the UUID of the controller above the physical port in the service plane.
        for _ in 0..<12 {
            var className = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
            guard IOObjectGetClass(entry, &className) == KERN_SUCCESS else { return nil }
            let driver = String(cString: className)
            if driver == "AppleHPMDevice" || driver.hasPrefix("AppleHPMDeviceHAL") {
                guard let raw = property(entry, "UUID") as? String else { return nil }
                return UUID(uuidString: raw)
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(entry)
            entry = parent
        }
        return nil
    }

    static func read(controllers: Set<UUID>) -> [UUID: Double] {
        guard !controllers.isEmpty else { return [:] }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return [:] }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return [:] }
        defer { IOServiceClose(connection) }
        return readings(for: controllers) { channel, field in
            readRegister(channel: channel, field: field, connection: connection)
        }
    }

    enum Register: String {
        case controller = "UI", present = "PR", volts = "JV", amps = "JI"

        var format: (type: String, size: Int) {
            switch self {
            case .controller: return ("hex_", 16)
            case .present: return ("ui8 ", 1)
            case .volts, .amps: return ("flt ", MemoryLayout<Float>.size)
            }
        }
    }

    static func readings(for controllers: Set<UUID>, register: (Int, Register) -> [UInt8]?) -> [UUID: Double] {
        func float(_ bytes: [UInt8]?) -> Double? {
            guard let bytes, bytes.count == MemoryLayout<Float>.size else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        }

        var readings: [UUID: Double] = [:]
        var seen: Set<UUID> = []
        for channel in 1...4 {
            guard let bytes = register(channel, .controller), bytes.count == 16,
                  bytes.contains(where: { $0 != 0 }), bytes.contains(where: { $0 != 255 }) else { continue }
            let controller = NSUUID(uuidBytes: bytes) as UUID
            guard controllers.contains(controller) else { continue }
            guard seen.insert(controller).inserted else {
                readings.removeValue(forKey: controller)
                continue
            }
            // A disabled rail often returns two real zeros. Its state says nothing
            // about incoming power. A live, powered rail with zero measured amps can
            // report true zero delivery. Recheck presence in case of a disconnect.
            guard register(channel, .present) == [1],
                  let volts = float(register(channel, .volts)), (2...55).contains(volts),
                  let amps = float(register(channel, .amps)), (0...6).contains(amps),
                  register(channel, .present) == [1] else { continue }
            readings[controller] = volts * amps
        }
        return readings
    }

    // AppleSMC's read ABI uses an 80-byte request/reply. Named byte offsets keep
    // this independent of Swift structure layout. Unknown types or ABIs yield nil.
    private enum Packet {
        static let count = 80
        static let key = 0..<4
        static let size = 28..<32
        static let type = 32..<36
        static let result = 40
        static let status = 41
        static let operation = 42
        static let payload = 48
    }

    private static func readRegister(channel: Int, field: Register, connection: io_connect_t) -> [UInt8]? {
        let key = "D\(channel)\(field.rawValue)"
        var request = [UInt8](repeating: 0, count: Packet.count)
        request.replaceSubrange(Packet.key, with: key.utf8.reversed())
        func execute() -> [UInt8]? {
            var reply = [UInt8](repeating: 0, count: Packet.count)
            var count = reply.count
            let status = IOConnectCallStructMethod(connection, 2, &request, Packet.count, &reply, &count)
            guard status == KERN_SUCCESS, count == Packet.count,
                  reply[Packet.result] == 0, reply[Packet.status] == 0 else { return nil }
            return reply
        }

        let format = field.format
        request[Packet.operation] = 9 // Get key info.
        guard let info = execute(),
              info[Packet.type].elementsEqual(format.type.utf8.reversed()),
              info.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: Packet.size.lowerBound, as: UInt32.self) }) == UInt32(format.size)
        else { return nil }
        request[Packet.type] = info[Packet.type]
        request[Packet.size] = info[Packet.size]
        request[Packet.operation] = 5 // Read key.
        guard let reply = execute() else { return nil }
        return Array(reply[Packet.payload..<(Packet.payload + format.size)])
    }
}
