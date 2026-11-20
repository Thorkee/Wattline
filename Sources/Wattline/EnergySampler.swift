import Darwin
import Foundation

struct EnergyConsumer: Identifiable, Sendable {
    let id: String
    let name: String
    let bundlePath: String?
    let value: Double
}

enum EnergyMetric: Sendable { case power, cpu }

enum AppActivityMetric: Sendable { case cpu, memory, power }

struct EnergyRanking: Sendable {
    let metric: EnergyMetric
    let consumers: [EnergyConsumer]
    var isAvailable: Bool = true
}

/// Tracks CPU energy charged to readable tasks by the kernel. Display, GPU,
/// charging and other system-wide power are outside this counter.
final class EnergySampler {
    struct ProcessUsage {
        let start: UInt64
        let energy: UInt64?
        let cpu: UInt64
        let parent: pid_t
        let executable: String
        let bundlePath: String?
        var executableID: UUID? = nil
        var footprint: UInt64? = nil
    }

    private var previous: [pid_t: ProcessUsage] = [:]
    private var lastTime: UInt64?
    private let nanosecondsPerTick: Double

    init() {
        var scale = mach_timebase_info_data_t()
        mach_timebase_info(&scale)
        nanosecondsPerTick = Double(scale.numer) / Double(scale.denom)
    }

    /// Call serially. First observation establishes a baseline.
    func sample() -> EnergyRanking? {
        sampleRates(forceCPU: false)
    }

    func sampleApps(_ metric: AppActivityMetric) -> [EnergyConsumer]? {
        if metric == .memory { return Self.rankMemory(snapshot()) }
        guard let ranking = sampleRates(forceCPU: metric == .cpu), ranking.isAvailable,
              metric != .power || ranking.metric == .power else { return nil }
        return ranking.consumers
    }

    private func sampleRates(forceCPU: Bool) -> EnergyRanking? {
        let now = mach_absolute_time()
        let processes = snapshot()
        defer {
            previous = processes
            lastTime = now
        }
        guard let lastTime, now > lastTime else { return nil }
        return Self.rank(previous: previous, current: processes, from: lastTime, to: now,
                         nanosecondsPerTick: nanosecondsPerTick, forceCPU: forceCPU)
    }

    static func rank(previous: [pid_t: ProcessUsage], current: [pid_t: ProcessUsage],
                     from: UInt64, to: UInt64, nanosecondsPerTick: Double, forceCPU: Bool = false) -> EnergyRanking {
        guard to > from, nanosecondsPerTick.isFinite, nanosecondsPerTick > 0 else {
            return EnergyRanking(metric: .cpu, consumers: [], isAvailable: false)
        }

        let ticks = Double(to - from)
        var cpuTotals: [String: Double] = [:]
        var energyTotals: [String: Double] = [:]
        var bundles: Set<String> = []
        var comparedTasks = 0
        var observedEnergyCounter = false
        var missingEnergyForActiveTask = false
        for (pid, process) in current {
            let old = previous[pid]
            let sameTask = old?.start == process.start
            if sameTask, let old {
                // An exec can keep its PID, start time and counters while replacing its image.
                guard old.executableID == process.executableID, old.executable == process.executable else { continue }
            } else {
                // A task born within this interval has a known zero baseline.
                guard process.start >= from, process.start <= to else { continue }
            }

            let initialCPU = sameTask ? (old?.cpu ?? 0) : 0
            guard process.cpu >= initialCPU else { continue }
            let cpuDelta = process.cpu - initialCPU
            let initialEnergy: UInt64? = sameTask ? old?.energy : 0
            var energyDelta: UInt64?
            if let start = initialEnergy, let end = process.energy, end >= start {
                energyDelta = end - start
                observedEnergyCounter = observedEnergyCounter || end > 0
            }

            comparedTasks += 1
            guard cpuDelta > 0 || (energyDelta ?? 0) > 0 else { continue }
            let owner = owningBundle(of: process, among: current)
            if sameTask, let old, owner != owningBundle(of: old, among: previous) {
                // Reparenting or an ancestor's exec makes this interval's attribution ambiguous.
                continue
            }
            let id = owner ?? process.executable
            if owner != nil { bundles.insert(id) }
            if cpuDelta > 0 {
                cpuTotals[id, default: 0] += Double(cpuDelta)
                if energyDelta == nil || process.energy == 0 { missingEnergyForActiveTask = true }
            }
            if let energyDelta, energyDelta > 0 {
                energyTotals[id, default: 0] += Double(energyDelta)
            }
        }

        // Unsupported machines return zero energy. A nonzero lifetime counter
        // alone also cannot measure this interval if CPU time advanced but joules did not.
        let useEnergy = !forceCPU && observedEnergyCounter && !missingEnergyForActiveTask
            && (!energyTotals.isEmpty || cpuTotals.isEmpty)
        let metric: EnergyMetric = useEnergy ? .power : .cpu
        let totals = useEnergy ? energyTotals : cpuTotals
        let consumers = topConsumers(totals: totals, bundles: bundles) { delta in
            // nJ / ns gives watts. CPU time is expressed as percent of one logical core.
            useEnergy ? delta / (ticks * nanosecondsPerTick) : 100 * delta / ticks
        }
        return EnergyRanking(metric: metric, consumers: consumers, isAvailable: comparedTasks > 0)
    }

    static func rankMemory(_ processes: [pid_t: ProcessUsage]) -> [EnergyConsumer]? {
        var totals: [String: Double] = [:]
        var bundles: Set<String> = []
        var hasReading = false
        for process in processes.values {
            guard let footprint = process.footprint else { continue }
            hasReading = true
            guard footprint > 0 else { continue }
            let owner = owningBundle(of: process, among: processes)
            let id = owner ?? process.executable
            if owner != nil { bundles.insert(id) }
            totals[id, default: 0] += Double(footprint)
        }
        return hasReading ? topConsumers(totals: totals, bundles: bundles) { $0 } : nil
    }

    private static func topConsumers(totals: [String: Double], bundles: Set<String>,
                                     value: (Double) -> Double) -> [EnergyConsumer] {
        let top = totals.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(3)
        return top.map { id, total in
            let bundle = bundles.contains(id) ? id : nil
            let name: String
            if let bundle {
                let info = Bundle(path: bundle)
                name = info?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? info?.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
            } else {
                name = serviceName(for: id)
            }
            return EnergyConsumer(id: id, name: name, bundlePath: bundle, value: value(total))
        }
    }

    private static func serviceName(for path: String) -> String {
        let executable = URL(fileURLWithPath: path).lastPathComponent
        guard path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/sbin/") else { return executable }
        switch executable {
        case "com.apple.Virtualization.VirtualMachine": return "Virtual machine"
        case "cfprefsd": return "Preferences service"
        case "mdworker_shared": return "Spotlight indexing"
        case "mds_stores": return "Spotlight database"
        default: return executable
        }
    }

    private static func owningBundle(of process: ProcessUsage, among table: [pid_t: ProcessUsage]) -> String? {
        var candidate = process
        var visited = Set<pid_t>()
        while candidate.bundlePath == nil, candidate.parent > 1, visited.insert(candidate.parent).inserted,
              let ancestor = table[candidate.parent], ancestor.start <= candidate.start {
            candidate = ancestor
        }
        return candidate.bundlePath
    }

    static func outerBundle(in executable: String) -> String? {
        guard let suffix = executable.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(executable[..<executable.index(before: suffix.upperBound)])
    }

    private func snapshot() -> [pid_t: ProcessUsage] {
        // proc_listallpids returns a PID count on both the size and fill calls.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [:] }
        var ids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = ids.withUnsafeMutableBytes { Int(proc_listallpids($0.baseAddress, Int32($0.count))) }
        guard count > 0 else { return [:] }
        var result: [pid_t: ProcessUsage] = [:]
        result.reserveCapacity(previous.count)
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in ids.prefix(count) where pid > 0 {
            guard let counters = Self.counters(pid) else { continue }
            // Refresh ownership even when the image UUID is unchanged. Daemons
            // can be adopted, and executables with identical UUIDs can live in different apps.
            let executable: String
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 || proc_name(pid, &path, UInt32(path.count)) > 0 {
                executable = String(cString: path)
            } else {
                executable = "Process \(pid)"
            }
            let bundle = Self.outerBundle(in: executable)
            var parent: pid_t = 0
            if bundle == nil {
                var bsd = proc_bsdshortinfo()
                let size = Int32(MemoryLayout.size(ofValue: bsd))
                if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &bsd, size) == size {
                    parent = pid_t(bsd.pbsi_ppid)
                }
            }
            result[pid] = ProcessUsage(start: counters.start, energy: counters.energy, cpu: counters.cpu,
                                       parent: parent, executable: executable, bundlePath: bundle,
                                       executableID: counters.uuid, footprint: counters.footprint)
        }
        return result
    }

    private static func counters(_ pid: pid_t) -> (start: UInt64, energy: UInt64?, cpu: UInt64, uuid: UUID, footprint: UInt64)? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        if result == 0 {
            return (info.ri_proc_start_abstime, info.ri_energy_nj, info.ri_user_time + info.ri_system_time,
                    UUID(uuid: info.ri_uuid), info.ri_phys_footprint)
        }
        guard errno == EINVAL || errno == ENOTSUP else { return nil }
        var legacy = rusage_info_v0()
        let legacyResult = withUnsafeMutablePointer(to: &legacy) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        guard legacyResult == 0 else { return nil }
        return (legacy.ri_proc_start_abstime, nil, legacy.ri_user_time + legacy.ri_system_time,
                UUID(uuid: legacy.ri_uuid), legacy.ri_phys_footprint)
    }
}
