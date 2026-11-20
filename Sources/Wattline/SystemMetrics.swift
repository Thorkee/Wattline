import Darwin
import Dispatch
import Foundation
import SystemConfiguration

struct SystemSample: Sendable {
    let date: Date
    let cpuPercent: Double?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64?
    let swapUsed: UInt64?
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
    let networkInterfaces: [String]
    var cpuUserPercent: Double?
    var cpuSystemPercent: Double?
    var memoryWired: UInt64?
    var memoryCompressed: UInt64?
    var memoryPressure: String?
    var networkLabels: [String] = []
    var diskReadBytesPerSecond: Double?
    var diskWriteBytesPerSecond: Double?
    var storageTotal: UInt64?
    var storageAvailable: UInt64?

    var memoryBytesForChart: Double? { memoryUsed.map { Double($0) } }
}

actor SystemMetricsSampler {
    private var previous: SystemCounters?
    private var network = NetworkInterfaces()
    private let maxInterval: TimeInterval

    init(maxInterval: TimeInterval = 15) {
        self.maxInterval = maxInterval
    }

    func reset() {
        previous = nil
        network = NetworkInterfaces()
    }

    func sample() -> SystemSample {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let counters = SystemCounters(date: now, uptime: uptime, cpu: Self.cpuTicks(host),
                                      links: network.counters(at: uptime), disks: StorageMetrics.diskCounters())
        let interval = previous.flatMap { counters.interval(since: $0, maxInterval: maxInterval) }
        let cpu = interval == nil ? nil : counters.cpuLoad(since: previous?.cpu)
        let throughput = interval.flatMap { counters.traffic(since: previous?.links, seconds: $0) }
        let disk = interval.flatMap { StorageMetrics.rates(from: previous?.disks, to: counters.disks, seconds: $0) }
        previous = counters

        let total = ProcessInfo.processInfo.physicalMemory
        let memory = Self.memory(host, total: total)
        let storage = StorageMetrics.startupCapacity()
        let links = counters.links?.keys.map(\.name).sorted() ?? []
        return SystemSample(date: now, cpuPercent: cpu.map { $0.user + $0.system },
                            memoryUsed: memory?.used, memoryTotal: total > 0 ? total : nil,
                            swapUsed: Self.swapBytes(), downloadBytesPerSecond: throughput?.down,
                            uploadBytesPerSecond: throughput?.up,
                            networkInterfaces: links,
                            cpuUserPercent: cpu?.user, cpuSystemPercent: cpu?.system,
                            memoryWired: memory?.wired, memoryCompressed: memory?.compressed,
                            memoryPressure: Self.memoryPressure(), networkLabels: links.map { network.labels[$0] ?? $0 },
                            diskReadBytesPerSecond: disk?.read, diskWriteBytesPerSecond: disk?.write,
                            storageTotal: storage?.total, storageAvailable: storage?.available)
    }

    private static func cpuTicks(_ host: host_t) -> SystemCounters.CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let expected = count
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, count == expected else { return nil }
        let ticks = info.cpu_ticks
        return .init(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    private static func memory(_ host: host_t, total: UInt64) -> MemoryFootprint? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        // The structure can grow in new SDKs. These fields were present in rev 1.
        guard result == KERN_SUCCESS, let rev1Bytes = MemoryLayout<vm_statistics64_data_t>.offset(of: \.swapped_count),
              Int(count) * MemoryLayout<integer_t>.size >= rev1Bytes else { return nil }
        return MemoryFootprint(anonymous: info.internal_page_count, purgeable: info.purgeable_count,
                               wired: info.wire_count, compressed: info.compressor_page_count,
                               pageSize: UInt64(getpagesize()), total: total)
    }

    private static func swapBytes() -> UInt64? {
        var info = xsw_usage()
        var length = MemoryLayout.size(ofValue: info)
        guard sysctlbyname("vm.swapusage", &info, &length, nil, 0) == 0,
              length == MemoryLayout<xsw_usage>.size, info.xsu_used <= info.xsu_total else { return nil }
        return info.xsu_used
    }

    private static func memoryPressure() -> String? {
        // XNU publishes this sysctl in Dispatch's public memory-pressure event encoding.
        var level: UInt32 = 0
        var length = MemoryLayout.size(ofValue: level)
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0,
              length == MemoryLayout<UInt32>.size else { return nil }
        switch UInt(level) {
        case DispatchSource.MemoryPressureEvent.normal.rawValue: return "Normal"
        case DispatchSource.MemoryPressureEvent.warning.rawValue: return "Elevated"
        case DispatchSource.MemoryPressureEvent.critical.rawValue: return "Critical"
        default: return nil
        }
    }
}

struct MemoryFootprint {
    let used: UInt64
    let wired: UInt64
    let compressed: UInt64

    init?(anonymous: UInt32, purgeable: UInt32, wired: UInt32, compressed: UInt32,
          pageSize: UInt64, total: UInt64) {
        // Pageable anonymous memory, kernel-wired pages, and the compressor's actual
        // resident pages are disjoint. File cache and reclaimable purgeable RAM are excluded.
        let appPages = UInt64(anonymous - min(anonymous, purgeable))
        let pages = appPages + UInt64(wired) + UInt64(compressed)
        let (used, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        guard total > 0, pageSize > 0, !overflow, used <= total else { return nil }
        self.used = used
        self.wired = UInt64(wired) * pageSize
        self.compressed = UInt64(compressed) * pageSize
    }
}

struct SystemCounters {
    struct CPUTicks {
        let user, system, idle, nice: UInt32
    }

    struct Link: Hashable {
        let name: String
        let index: UInt32
    }

    struct Traffic {
        let received, sent: UInt64
    }

    let date: Date
    let uptime: TimeInterval
    let cpu: CPUTicks?
    let links: [Link: Traffic]?
    var disks: [UInt64: StorageMetrics.Bytes]?

    func interval(since previous: Self, maxInterval: TimeInterval = 15) -> TimeInterval? {
        let seconds = uptime - previous.uptime
        guard seconds > 0, seconds <= maxInterval,
              abs(date.timeIntervalSince(previous.date) - seconds) <= 2 else { return nil }
        return seconds
    }

    func cpuLoad(since previous: CPUTicks?) -> (user: Double, system: Double)? {
        guard let cpu, let previous, cpu.user >= previous.user, cpu.system >= previous.system,
              cpu.idle >= previous.idle, cpu.nice >= previous.nice else { return nil }
        let user = Double(cpu.user - previous.user) + Double(cpu.nice - previous.nice)
        let system = Double(cpu.system - previous.system)
        let total = user + system + Double(cpu.idle - previous.idle)
        guard total > 0 else { return nil }
        return (100 * user / total, 100 * system / total)
    }

    func traffic(since previous: [Link: Traffic]?, seconds: TimeInterval) -> (down: Double, up: Double)? {
        guard seconds.isFinite, seconds > 0, let links, !links.isEmpty, let previous,
              links.keys == previous.keys else { return nil }
        var down = 0.0, up = 0.0
        for (link, current) in links {
            guard let old = previous[link], current.received >= old.received, current.sent >= old.sent else { return nil }
            down += Double(current.received - old.received)
            up += Double(current.sent - old.sent)
        }
        return (down / seconds, up / seconds)
    }
}

private struct NetworkInterfaces {
    private let store = SCDynamicStoreCreate(nil, "Wattline Monitor" as CFString, nil, nil)
    private var lastKeys: Set<String>?
    private var nextRefresh: TimeInterval = 0
    private(set) var labels: [String: String] = [:]

    mutating func counters(at uptime: TimeInterval) -> [SystemCounters.Link: SystemCounters.Traffic]? {
        let linkPattern = ["State:/Network/Interface/[^/]+/Link"] as CFArray
        let states = store.flatMap { SCDynamicStoreCopyMultiple($0, nil, linkPattern) as? [String: Any] }
        let keys = states.map { Set($0.keys) }
        if keys != lastKeys || uptime >= nextRefresh {
            guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
            // Count leaf Wi-Fi/Ethernet links. Bridge, VLAN, VPN and loopback
            // interfaces can carry the same packets as their underlying links.
            var discovered: [String: String] = [:]
            for interface in interfaces {
                let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
                guard type == kSCNetworkInterfaceTypeEthernet as String || type == kSCNetworkInterfaceTypeIEEE80211 as String,
                      let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
                discovered[name] = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? name
            }
            labels = discovered
            lastKeys = keys
            nextRefresh = uptime + 30
        }

        var result: [SystemCounters.Link: SystemCounters.Traffic] = [:]
        for name in labels.keys {
            let state = states?["State:/Network/Interface/" + name + "/Link"] as? [String: Any]
            if state?[kSCPropNetLinkActive as String] as? Bool == false { continue }
            let index = if_nametoindex(name)
            guard index > 0, let signedIndex = Int32(exactly: index) else { continue }
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, signedIndex, IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout.size(ofValue: data)
            // ifmibdata carries full-width byte counters, including on older Intel Macs.
            guard sysctl(&mib, UInt32(mib.count), &data, &size, nil, 0) == 0, size == MemoryLayout<ifmibdata>.size
            else { return nil }
            let flags = UInt32(IFF_UP | IFF_RUNNING)
            guard data.ifmd_flags & flags == flags else { continue }
            let actualName = withUnsafeBytes(of: data.ifmd_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard actualName == name else { return nil } // Interface index was reused during this read.
            result[.init(name: name, index: index)] = .init(received: data.ifmd_data.ifi_ibytes,
                                                          sent: data.ifmd_data.ifi_obytes)
        }
        return result
    }
}
