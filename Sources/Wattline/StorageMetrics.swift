import Darwin
import Foundation
import IOKit.storage

enum StorageMetrics {
    struct Bytes: Equatable {
        let read, written: UInt64
    }

    /// Mounted startup data filesystem. APFS volumes in the same container
    /// share available blocks; f_bavail reports space available to this user.
    static func startupCapacity() -> (total: UInt64, available: UInt64)? {
        var fs = statfs()
        if statfs("/System/Volumes/Data", &fs) != 0 {
            guard errno == ENOENT, statfs("/", &fs) == 0 else { return nil }
        }
        guard fs.f_bsize > 0, fs.f_blocks > 0, fs.f_bavail <= fs.f_blocks else { return nil }
        let (total, overflow) = fs.f_blocks.multipliedReportingOverflow(by: UInt64(fs.f_bsize))
        guard !overflow else { return nil }
        return (total, fs.f_bavail * UInt64(fs.f_bsize))
    }

    static func diskCounters() -> [UInt64: Bytes]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var disks: [UInt64: Bytes] = [:]
        var devices = Set<UInt64>()
        while case let driver = IOIteratorNext(iterator), driver != IO_OBJECT_NULL {
            defer { IOObjectRelease(driver) }
            var device: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(device) }
            guard IOObjectConformsTo(device, "IOBlockStorageDevice") != 0,
                  let properties = property(device, kIOPropertyProtocolCharacteristicsKey) as? [String: Any],
                  isInternalPhysicalBus(properties), hasFixedWholeMedia(driver) else { continue }

            // The driver owns the counters. A replaced driver or two competing
            // drivers for one device cannot form a single trustworthy interval.
            var deviceID: UInt64 = 0, driverID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(device, &deviceID) == KERN_SUCCESS, devices.insert(deviceID).inserted,
                  IORegistryEntryGetRegistryEntryID(driver, &driverID) == KERN_SUCCESS,
                  let stats = property(driver, kIOBlockStorageDriverStatisticsKey) as? [String: Any],
                  let read = counter(stats[kIOBlockStorageDriverStatisticsBytesReadKey]),
                  let written = counter(stats[kIOBlockStorageDriverStatisticsBytesWrittenKey]) else { return nil }
            disks[driverID] = Bytes(read: read, written: written)
        }
        return IOIteratorIsValid(iterator) != 0 && !disks.isEmpty ? disks : nil
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func hasFixedWholeMedia(_ driver: io_registry_entry_t) -> Bool {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != IO_OBJECT_NULL {
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOMedia") != 0, property(child, kIOMediaWholeKey) as? Bool == true,
               property(child, kIOMediaRemovableKey) as? Bool == false,
               property(child, kIOMediaEjectableKey) as? Bool == false { return true }
        }
        return false
    }

    static func isInternalPhysicalBus(_ properties: [String: Any]) -> Bool {
        guard properties[kIOPropertyPhysicalInterconnectLocationKey] as? String == "Internal",
              let bus = properties[kIOPropertyPhysicalInterconnectTypeKey] as? String else { return false }
        switch bus {
        case kIOPropertyPhysicalInterconnectTypeAppleFabric, kIOPropertyPhysicalInterconnectTypePCIExpress,
             kIOPropertyPhysicalInterconnectTypePCI, kIOPropertyPhysicalInterconnectTypeATA,
             kIOPropertyPhysicalInterconnectTypeSerialATA, kIOPropertyPhysicalInterconnectTypeSerialAttachedSCSI,
             kIOPropertyPhysicalInterconnectTypeSCSIParallel:
            return true
        default: return false
        }
    }

    private static func counter(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number), number.compare(0) != .orderedAscending else { return nil }
        return number.uint64Value
    }

    static func rates(from previous: [UInt64: Bytes]?, to current: [UInt64: Bytes]?,
                      seconds: TimeInterval) -> (read: Double, write: Double)? {
        guard let current, !current.isEmpty, let previous, current.keys == previous.keys,
              seconds.isFinite, seconds > 0 else { return nil }
        var read = 0.0, write = 0.0
        for (id, counters) in current {
            guard let old = previous[id], counters.read >= old.read, counters.written >= old.written else { return nil }
            read += Double(counters.read - old.read)
            write += Double(counters.written - old.written)
        }
        return (read / seconds, write / seconds)
    }
}
