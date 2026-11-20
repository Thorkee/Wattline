import AppKit
import Combine
import IOKit.ps

private actor EnergySamplingSession {
    private let sampler = EnergySampler()

    func sample() -> EnergyRanking? {
        sampler.sample()
    }
}

extension PowerState {
    var title: String {
        switch self {
        case .charging: "Charging"
        case .pluggedDraining: "Draining while plugged in"
        case .onBattery: "On battery"
        case .holding: "Plugged in · Holding"
        case .full: "Fully charged"
        case .acPower: "AC power"
        case .ups: "On UPS power"
        case .unknown: "Status unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .charging: "bolt.fill"
        case .pluggedDraining: "exclamationmark.triangle.fill"
        case .onBattery: "battery.50percent"
        case .holding: "powerplug.fill"
        case .full: "battery.100percent"
        case .acPower: "powerplug.fill"
        case .ups: "externaldrive.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct PowerTimeline {
    private(set) var samples: [PowerReading] = []
    private(set) var breaks: Set<Date> = []
    private var lastUptime: TimeInterval?

    mutating func record(_ reading: PowerReading, uptime: TimeInterval, afterSleep: Bool = false) {
        let date = reading.date
        if let last = samples.last, let lastUptime {
            let wallElapsed = date.timeIntervalSince(last.date)
            if wallElapsed == 0 {
                samples[samples.count - 1] = reading
                if afterSleep { breaks.insert(date) }
                self.lastUptime = uptime
                return
            } else if wallElapsed < 0 {
                samples.removeAll(keepingCapacity: true)
                breaks.removeAll(keepingCapacity: true)
            } else if afterSleep || abs(wallElapsed - (uptime - lastUptime)) > 2 {
                breaks.insert(date)
            } else if wallElapsed < 1 {
                // A timer tick and a power-source notification can arrive together.
                return
            }
        }
        self.lastUptime = uptime
        let cutoff = date.addingTimeInterval(-15 * 60)
        samples.removeAll { $0.date < cutoff }
        breaks = breaks.filter { $0 >= cutoff }
        samples.append(reading)
    }
}

@MainActor
final class PowerMonitor: NSObject, ObservableObject {
    let historyArchive = MonitorHistory()
    let health = WattlineHealthMonitor()
    @Published private(set) var latest: PowerReading
    @Published private(set) var ranking: EnergyRanking?
    private var timeline = PowerTimeline()
    var history: [PowerReading] { timeline.samples }
    var historyBreaks: Set<Date> { timeline.breaks }
    private var timer: Timer?
    private var sourceChanges: CFRunLoopSource?
    private var rankingTask: Task<Void, Never>?
    @Published private(set) var panelVisible = false
    private var sleeping = false

    override init() {
        let reading = PowerReading.read()
        latest = reading
        super.init()
        timeline.record(reading, uptime: ProcessInfo.processInfo.systemUptime)
    }

    func start() {
        guard timer == nil else { return }
        refresh(afterSleep: false)
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(sample), userInfo: nil, repeats: true)
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().sample()
            }
        }
        sourceChanges = IOPSNotificationCreateRunLoopSource(callback, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let sourceChanges { CFRunLoopAddSource(CFRunLoopGetMain(), sourceChanges, .commonModes) }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        updateRanking()
    }

    private func updateRanking() {
        rankingTask?.cancel()
        rankingTask = nil
        ranking = nil
        guard panelVisible && !sleeping else { return }
        let session = EnergySamplingSession()
        rankingTask = Task { [weak self] in
            while !Task.isCancelled {
                let result = await session.sample()
                guard !Task.isCancelled, self != nil else { return }
                self?.ranking = result
                do {
                    try await Task.sleep(for: .seconds(result == nil ? 2 : 5))
                } catch { return }
            }
        }
    }

    func stop() {
        historyArchive.pause()
        setPanelVisible(false)
        timer?.invalidate()
        timer = nil
        if let sourceChanges { CFRunLoopSourceInvalidate(sourceChanges) }
        sourceChanges = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func willSleep() {
        health.reset()
        historyArchive.pause()
        sleeping = true
        updateRanking()
    }

    @objc private func didWake() {
        sleeping = false
        refresh(afterSleep: true)
        updateRanking()
    }

    @objc private func sample() {
        guard !sleeping else { return }
        refresh(afterSleep: false)
    }

    private func refresh(afterSleep: Bool) {
        let reading = PowerReading.read()
        let uptime = ProcessInfo.processInfo.systemUptime
        timeline.record(reading, uptime: uptime, afterSleep: afterSleep)
        latest = reading
        health.observe(power: reading, uptime: uptime, afterSleep: afterSleep)
        historyArchive.sampleIfDue(reading, uptime: uptime) { [weak self] metrics in
            self?.health.observe(system: metrics, uptime: ProcessInfo.processInfo.systemUptime)
        }
    }
}
