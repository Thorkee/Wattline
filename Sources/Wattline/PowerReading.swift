import Foundation
import IOKit
import IOKit.ps

enum PowerState: Equatable, Sendable {
    case charging, pluggedDraining, onBattery, holding, full, acPower, ups, unknown
}

struct PowerReading: Sendable {
    let date: Date
    let percent: Int?
    let connected: Bool?
    let charging: Bool?
    let full: Bool?
    let inputWatts: Double?
    let systemWatts: Double?
    /// Positive when energy enters the battery, negative when it leaves.
    let batteryWatts: Double?
    /// Maximum available on the current connection.
    var adapterWatts: Double?
    var hasInternalBattery: Bool? = nil
    var isOnUPS = false

    var state: PowerState {
        if isOnUPS { return .ups }
        if hasInternalBattery == false { return connected == true ? .acPower : .unknown }
        if connected == false { return .onBattery }
        if let batteryWatts {
            // Ignore small oscillations during charge maintenance.
            if batteryWatts > 0.5 { return .charging }
            if batteryWatts < -0.5 { return connected == true ? .pluggedDraining : .unknown }
        }
        if full == true { return .full }
        if batteryWatts == nil && charging == true { return .charging }
        if connected == true && (batteryWatts != nil || charging == false) { return .holding }
        return .unknown
    }

    static func read() -> PowerReading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        var registry: [String: Any] = [:]
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                registry = properties?.takeRetainedValue() as? [String: Any] ?? [:]
            }
        }

        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return decode(registry: registry, records: [], provider: nil, inventoryComplete: false)
        }
        let provider = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let items = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        let records = items?.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        } ?? []
        let inventoryComplete = items != nil && records.count == items?.count &&
            records.allSatisfy { $0[kIOPSTypeKey] is String }
        var reading = decode(registry: registry, records: records, provider: provider, inventoryComplete: inventoryComplete)
        if reading.hasInternalBattery == true, reading.connected == true, reading.adapterWatts == nil,
           let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            reading.adapterWatts = positiveWord(details[kIOPSPowerAdapterWattsKey])
        }
        return reading
    }

    static func decode(registry: [String: Any], records: [[String: Any]], provider: String?,
                       inventoryComplete: Bool, date: Date = Date()) -> PowerReading {
        let internalRecord = records.first {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && $0[kIOPSIsPresentKey] as? Bool != false
        }
        let batteryPresent: Bool?
        if internalRecord != nil { batteryPresent = true }
        else if let installed = registry["BatteryInstalled"] as? Bool { batteryPresent = installed }
        else if !registry.isEmpty { batteryPresent = true }
        else { batteryPresent = inventoryComplete ? false : nil }
        return decode(registry: registry, source: internalRecord ?? [:], provider: provider,
                      hasInternalBattery: batteryPresent, date: date)
    }

    static func decode(registry raw: [String: Any], source: [String: Any] = [:], provider: String? = nil,
                       hasInternalBattery: Bool? = nil, date: Date = Date()) -> PowerReading {
        let isOnUPS = provider == kIOPMUPSPowerKey
        // A driver can retain its last register block across sleep or disconnection.
        // Only apply age checks to recognizable Unix seconds. Older drivers
        // without a wall-clock timestamp still have usable electrical readings.
        let registry: [String: Any]
        if let updated = nonnegativeValue(raw["UpdateTime"]), (978_307_200..<4_102_444_800).contains(updated),
           abs(date.timeIntervalSince1970 - updated) > 180 {
            registry = [:]
        } else {
            registry = raw
        }
        let telemetry = registry["PowerTelemetryData"] as? [String: Any] ?? [:]
        let reportedLoad = watts(telemetry["SystemLoad"])
        if hasInternalBattery == false {
            // A UPS's own percentage and charging flags describe its external pack.
            let onExternalPower = provider == kIOPMACPowerKey || isOnUPS
            return PowerReading(date: date, percent: nil, connected: onExternalPower ? true : nil,
                                charging: nil, full: nil, inputWatts: nil,
                                systemWatts: reportedLoad.flatMap { $0 > 0 ? $0 : nil }, batteryWatts: nil,
                                adapterWatts: nil, hasInternalBattery: false, isOnUPS: isOnUPS)
        }
        let adapter = registry["AdapterDetails"] as? [String: Any] ?? [:]
        let connected = registry["ExternalConnected"] as? Bool ?? {
            switch (source[kIOPSPowerSourceStateKey] as? String) ?? provider {
            case kIOPSACPowerValue: return true
            case kIOPMUPSPowerKey: return true
            case kIOPSBatteryPowerValue: return false
            default: return nil
            }
        }()
        let percent = percentage(current: registry["CurrentCapacity"], maximum: registry["MaxCapacity"])
            ?? percentage(current: source[kIOPSCurrentCapacityKey], maximum: source[kIOPSMaxCapacityKey])
            ?? percentage(current: registry["AppleRawCurrentCapacity"], maximum: registry["AppleRawMaxCapacity"])

        let reportedInput = watts(telemetry["SystemPowerIn"]).flatMap { $0 >= 0 ? $0 : nil }
        let reportedBattery = watts(telemetry["BatteryPower"])
        let emptyFrame = reportedLoad == 0 && (reportedInput ?? 0) == 0 && (reportedBattery ?? 0) == 0
        var input = connected == false ? 0 : reportedInput
        if connected != false, input == nil || (reportedLoad == 0 && input == 0) {
            // A measured DC voltage and current can still be available during a dropout.
            if let millivolts = positiveWord(telemetry["SystemVoltageIn"]), let milliamps = positiveWord(telemetry["SystemCurrentIn"]) {
                input = millivolts * milliamps / 1_000_000
            } else if emptyFrame {
                input = nil
            }
        }
        let terminalPower = terminalWatts(registry) ?? terminalWatts(source)
        var batteryWatts = reportedBattery ?? terminalPower
        var load = reportedLoad
        var charging = registry["IsCharging"] as? Bool ?? source[kIOPSIsChargingKey] as? Bool
        let staleAdapterFrame = connected == false && (reportedInput ?? 0) > 0.5
        if staleAdapterFrame || reportedLoad.map({ $0 <= 0 }) == true || exceedsInput(batteryWatts, input) {
            // An awake Mac has a positive load. Recover from independent battery
            // terminal power when the driver reports zero or an impossible balance.
            batteryWatts = exceedsInput(terminalPower, input) ? nil : terminalPower
            if batteryWatts == nil, reportedLoad == 0, !emptyFrame, !staleAdapterFrame,
               !exceedsInput(reportedBattery, input) {
                batteryWatts = reportedBattery
            }
            load = nil
            if batteryWatts == nil { charging = nil }
        } else if let reportedBattery, abs(reportedBattery) <= 0.5, let terminalPower, abs(terminalPower) > 0.5,
                  let input, let reportedLoad, !exceedsInput(terminalPower, input) {
            // A battery channel can stick at zero while the adapter and load
            // channels keep moving. Require independent agreement before replacing it.
            let balance = input - reportedLoad
            if balance.sign == terminalPower.sign, abs(balance - reportedBattery) > 0.5,
               abs(balance - terminalPower) <= max(0.5, abs(terminalPower) * 0.1) {
                batteryWatts = terminalPower
            }
        } else if let reportedBattery, let terminalPower, abs(reportedBattery) > 0.5,
                  abs(terminalPower) > 0.5, reportedBattery.sign != terminalPower.sign {
            // After switching inputs, BatteryPower can retain the opposite sign
            // even when the input and derived SystemLoad still balance on paper.
            load = nil
            if charging == (terminalPower > 0), !exceedsInput(terminalPower, input) {
                batteryWatts = terminalPower
            } else {
                batteryWatts = nil
                charging = nil
            }
        }
        if load == nil, let input, let batteryWatts, input > batteryWatts {
            load = input - batteryWatts
        }
        return PowerReading(
            date: date,
            percent: percent,
            connected: connected,
            charging: charging,
            full: registry["FullyCharged"] as? Bool ?? source[kIOPSIsChargedKey] as? Bool,
            inputWatts: input,
            systemWatts: load,
            batteryWatts: batteryWatts,
            adapterWatts: connected == false ? nil : positiveWord(adapter["Watts"]),
            hasInternalBattery: hasInternalBattery,
            isOnUPS: isOnUPS
        )
    }

    private static func exceedsInput(_ batteryWatts: Double?, _ inputWatts: Double?) -> Bool {
        guard let batteryWatts, let inputWatts else { return false }
        return batteryWatts > inputWatts + 0.5
    }

    private static func watts(_ raw: Any?) -> Double? {
        guard let milliwatts = signedValue(raw), abs(milliwatts) < Double(Int32.max) else { return nil }
        return milliwatts / 1_000
    }

    private static func terminalWatts(_ registry: [String: Any]) -> Double? {
        // Smart Battery current is a signed 16-bit mA value. A missing SMBus
        // voltage/capacity may be published as the unsigned all-ones sentinel.
        func current(_ value: Any?) -> Double? {
            signedValue(value).flatMap { (-32_768...32_767).contains($0) ? $0 : nil }
        }
        guard let current = current(registry["InstantAmperage"]) ?? current(registry["Amperage"]) ?? current(registry[kIOPSCurrentKey]),
              let voltage = positiveWord(registry[kIOPSVoltageKey]) else { return nil }
        // IOKit exposes battery terminal voltage in mV and current in mA.
        return current * voltage / 1_000_000
    }

    private static func percentage(current: Any?, maximum: Any?) -> Int? {
        guard let current = nonnegativeValue(current), let maximum = nonnegativeValue(maximum),
              maximum > 0, maximum != 65_535, current <= maximum else { return nil }
        return Int((current / maximum * 100).rounded())
    }

    private static func nonnegativeValue(_ value: Any?) -> Double? {
        guard let value = signedValue(value), value >= 0 else { return nil }
        return value
    }

    private static func positiveWord(_ value: Any?) -> Double? {
        guard let number = nonnegativeValue(value), number > 0, number < 65_535 else { return nil }
        return number
    }

    private static func signedValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        if CFNumberIsFloatType(number) {
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        // Some drivers expose signed readings as unsigned, two's-complement integers.
        let integer = number.int64Value
        if integer > Int32.max && integer <= UInt32.max {
            return Double(Int32(bitPattern: UInt32(integer)))
        }
        return Double(integer)
    }
}
