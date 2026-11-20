import Foundation

struct HealthIssue: Identifiable, Equatable, Sendable {
    enum Severity: Int, Sendable { case warning, critical }

    let id: String
    let title: String
    let message: String
    let severity: Severity
}

struct HealthCheckUpdate: Equatable, Sendable {
    let active: [HealthIssue]
    let newAlerts: [HealthIssue]
}

struct HealthChecks {
    private enum Check: String, CaseIterable {
        case power = "external-power-drain"
        case thermal = "thermal-pressure"
        case memory = "memory-pressure"
        case storage = "startup-disk-space"

        var maxGap: TimeInterval {
            switch self {
            case .power, .thermal: 20
            case .memory, .storage: 120
            }
        }

        var confirmationTime: TimeInterval {
            switch self {
            case .power: 180
            case .thermal: 90
            case .memory, .storage: 120
            }
        }

        var criticalConfirmationTime: TimeInterval { self == .thermal ? 15 : confirmationTime }

        var recoveryTime: TimeInterval {
            switch self {
            case .power, .thermal: 30
            case .memory, .storage: 60
            }
        }

        func issue(_ severity: HealthIssue.Severity) -> HealthIssue {
            let title: String
            let message: String
            switch self {
            case .power:
                title = "Battery draining on external power"
                message = "Your battery has supplied power for three minutes while the Mac is plugged in. Check the input and battery readings in Power."
            case .thermal:
                title = severity == .critical ? "Critical thermal pressure" : "High thermal pressure"
                message = "macOS reports sustained thermal pressure. Open CPU to see which apps are active."
            case .memory:
                title = "Critical memory pressure"
                message = "macOS has reported critical memory pressure for two minutes. Open Memory to review the largest apps."
            case .storage:
                title = "Startup disk is nearly full"
                message = "Your startup disk has very little space available. Open Storage to see which apps and folders use the most space."
            }
            return HealthIssue(id: rawValue, title: title, message: message, severity: severity)
        }
    }

    private enum Signal { case unavailable, normal, raised(HealthIssue.Severity) }

    private struct Episode {
        var active: HealthIssue.Severity?
        var raisedSince: TimeInterval?
        var criticalSince: TimeInterval?
        var normalSince: TimeInterval?
        var lastAlert: TimeInterval?
        var previous: (date: Date, uptime: TimeInterval)?

        mutating func clear() {
            active = nil
            raisedSince = nil
            criticalSince = nil
            normalSince = nil
            previous = nil
        }

        mutating func observe(_ signal: Signal, check: Check, date: Date, uptime: TimeInterval) -> HealthIssue? {
            if let previous {
                let interval = uptime - previous.uptime
                // Sleep and clock corrections must not contribute to time spent in an abnormal state.
                if interval < 0 || interval > check.maxGap || abs(date.timeIntervalSince(previous.date) - interval) > 2 {
                    clear()
                }
            }
            previous = (date, uptime)
            switch signal {
            case .unavailable:
                clear()
            case .normal:
                raisedSince = nil
                criticalSince = nil
                if active != nil {
                    let start = normalSince ?? uptime
                    normalSince = start
                    if uptime - start >= check.recoveryTime { clear() }
                }
            case .raised(let severity):
                normalSince = nil
                let start = raisedSince ?? uptime
                raisedSince = start
                criticalSince = severity == .critical ? criticalSince ?? uptime : nil
                let critical = criticalSince.map { uptime - $0 >= check.criticalConfirmationTime } ?? false
                guard critical || uptime - start >= check.confirmationTime else { return nil }
                let confirmed: HealthIssue.Severity = critical ? .critical : .warning
                let first = active == nil
                active = confirmed
                if first, lastAlert.map({ uptime < $0 || uptime - $0 >= 1_800 }) ?? true {
                    lastAlert = uptime
                    return check.issue(confirmed)
                }
            }
            return nil
        }
    }

    private var episodes: [Check: Episode] = [:]

    /// Restores the observation windows after sleep or a settings change. Cooldowns survive a short interruption.
    mutating func resetObservations() {
        for check in Check.allCases { episodes[check]?.clear() }
    }

    mutating func observe(power: PowerReading, thermal: ProcessInfo.ThermalState, uptime: TimeInterval,
                          afterSleep: Bool = false) -> HealthCheckUpdate {
        if afterSleep { resetObservations() }
        let drain: Signal
        if power.connected == true, !power.isOnUPS, power.hasInternalBattery != false,
           let watts = power.batteryWatts, watts.isFinite {
            let threshold = episodes[.power]?.active == nil ? -2.0 : -1.0
            drain = watts <= threshold ? .raised(.warning) : .normal
        } else {
            drain = .unavailable
        }
        let heat: Signal
        switch thermal {
        case .nominal, .fair: heat = .normal
        case .serious: heat = .raised(.warning)
        case .critical: heat = .raised(.critical)
        @unknown default: heat = .unavailable
        }
        return observe([(.power, drain), (.thermal, heat)], date: power.date, uptime: uptime)
    }

    mutating func observe(system: SystemSample, uptime: TimeInterval) -> HealthCheckUpdate {
        let memory: Signal
        switch system.memoryPressure {
        case "Critical": memory = .raised(.critical)
        case "Normal", "Elevated": memory = .normal
        default: memory = .unavailable
        }

        let space: Signal
        if let total = system.storageTotal, total > 0, let free = system.storageAvailable, free <= total {
            let fraction = Double(free) / Double(total)
            let recovering = episodes[.storage]?.active != nil
            let low = free < (recovering ? 7_000_000_000 : 5_000_000_000) && fraction < (recovering ? 0.05 : 0.03)
            space = low ? .raised(free < 1_000_000_000 ? .critical : .warning) : .normal
        } else {
            space = .unavailable
        }
        return observe([(.memory, memory), (.storage, space)], date: system.date, uptime: uptime)
    }

    private mutating func observe(_ observations: [(Check, Signal)], date: Date, uptime: TimeInterval) -> HealthCheckUpdate {
        guard uptime.isFinite, date.timeIntervalSince1970.isFinite else {
            resetObservations()
            return HealthCheckUpdate(active: [], newAlerts: [])
        }
        for check in Check.allCases {
            if let previous = episodes[check]?.previous, uptime - previous.uptime > check.maxGap {
                episodes[check]?.clear()
            }
        }
        var alerts: [HealthIssue] = []
        for (check, signal) in observations {
            if let issue = episodes[check, default: Episode()].observe(signal, check: check, date: date, uptime: uptime) {
                alerts.append(issue)
            }
        }
        let active = Check.allCases.compactMap { check in episodes[check]?.active.map(check.issue) }
            .sorted { $0.severity.rawValue > $1.severity.rawValue }
        return HealthCheckUpdate(active: active, newAlerts: alerts)
    }
}
