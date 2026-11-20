import SwiftUI

private enum Resource: String, CaseIterable, Identifiable {
    case cpu = "CPU", memory = "Memory", network = "Network", storage = "Storage", power = "Power"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.down.left.arrow.up.right"
        case .storage: "internaldrive"
        case .power: "bolt.fill"
        }
    }
    var title: String {
        switch self {
        case .cpu: "CPU activity"
        case .memory: "Memory usage"
        case .network: "Network traffic"
        case .storage: "Disk activity"
        case .power: "Mac power draw"
        }
    }
    var appMetric: AppActivityMetric? {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .power: .power
        case .network, .storage: nil
        }
    }
    var tint: Color {
        switch self {
        case .cpu: WattlineStyle.copper
        case .memory: WattlineStyle.iris
        case .network: WattlineStyle.jade
        case .storage: WattlineStyle.marine
        case .power: WattlineStyle.gold
        }
    }
}

private enum StoragePage: String { case usage, activity }
private enum PowerPage { case activity, ports }

private struct MonitorFrame {
    let system: SystemSample
    let power: PowerReading?
    let resumes: Bool
    let maximumGap: TimeInterval

    var historical: HistorySample {
        HistorySample(date: system.date, cpuPercent: system.cpuPercent, memoryUsed: system.memoryUsed,
                      downloadBytesPerSecond: system.downloadBytesPerSecond, uploadBytesPerSecond: system.uploadBytesPerSecond,
                      systemWatts: power?.systemWatts, diskReadBytesPerSecond: system.diskReadBytesPerSecond,
                      diskWriteBytesPerSecond: system.diskWriteBytesPerSecond, startsSegment: resumes)
    }
}

enum MonitorFormat {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }

    static func memory(_ bytes: UInt64?) -> String {
        memoryReading(bytes.map { Double($0) })
    }

    static func memoryReading(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        return scaled(bytes, base: 1024, units: ["B", "KB", "MB", "GB", "TB"])
    }

    static func rate(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "—" }
        return scaled(bytes, base: 1000, units: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"])
    }

    private static func scaled(_ value: Double, base: Double, units: [String]) -> String {
        var scaled = value
        var i = 0
        while scaled >= base && i < units.count - 1 {
            scaled /= base
            i += 1
        }
        let digits = i == 0 || scaled >= 100 ? 0 : 1
        return scaled.formatted(.number.precision(.fractionLength(0...digits))) + " " + units[i]
    }
}

struct SystemMonitorView: View {
    @ObservedObject var power: PowerMonitor
    @ObservedObject var visibility: MonitorVisibility
    @ObservedObject private var archive: MonitorHistory
    @ObservedObject var navigation: WattlineNavigation
    @StateObject private var diskInventory = StorageBreakdownModel()
    @AppStorage("wattlineSidebarResource") private var resource: Resource = .power
    @AppStorage("wattlineStoragePage") private var storagePage: StoragePage = .usage
    @State private var powerPage = PowerPage.activity
    @AppStorage(WattlinePreferences.historyRangeKey) private var savedRange = 3_600
    @AppStorage(WattlinePreferences.refreshKey) private var savedRefreshInterval = 2
    @State private var showsApps = true
    @State private var frames: [MonitorFrame] = []
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionHighlight
    private let coreCount = ProcessInfo.processInfo.activeProcessorCount
    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    init(power: PowerMonitor, visibility: MonitorVisibility, navigation: WattlineNavigation) {
        self.navigation = navigation
        self.power = power
        self.visibility = visibility
        self.archive = power.historyArchive
    }

    private var duration: Int { WattlinePreferences.historyRange(savedRange) }
    private var refreshInterval: Int { WattlinePreferences.refreshInterval(savedRefreshInterval) }
    private var sample: SystemSample? { frames.last?.system }
    private var currentPower: PowerReading? { frames.last?.power }
    private var end: Date { sample?.date ?? power.latest.date }
    private var timeline: [TimelineSample] {
        let gaps = Dictionary(uniqueKeysWithValues: frames.map { ($0.system.date, $0.maximumGap) })
        return MonitorTimeline.merge(archive: archive.samples, live: frames.map(\.historical),
                                     from: end.addingTimeInterval(-Double(duration)), through: end, liveGaps: gaps)
    }
    private var secondaryTrace: Color { resource == .storage ? WattlineStyle.iris : WattlineStyle.copper }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if navigation.showsSettings {
                WattlineSettings(shortcutAvailable: navigation.shortcutAvailable, reading: power.latest, health: power.health)
            } else {
                resourcePage
            }
        }
        .task(id: visibility.isSampling ? refreshInterval : nil) {
            guard visibility.isSampling else { return }
            let interval = refreshInterval
            let maximumGap = TimeInterval(interval * 3)
            let sampler = SystemMetricsSampler(maxInterval: maximumGap)
            var resumes = true
            while !Task.isCancelled {
                let next = await sampler.sample()
                guard !Task.isCancelled else { break }
                let reading = power.latest
                let fresh = abs(reading.date.timeIntervalSince(next.date)) <= 12
                if let last = frames.last, last.system.date >= next.date { frames.removeAll() }
                frames.removeAll { next.date.timeIntervalSince($0.system.date) > 300 }
                frames.append(MonitorFrame(system: next, power: fresh ? reading : nil, resumes: resumes, maximumGap: maximumGap))
                resumes = false
                do { try await Task.sleep(for: .seconds(interval)) } catch { break }
            }
        }
    }

    private var resourcePage: some View {
        GeometryReader { area in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if resource == .storage {
                        HStack {
                            pageTitle("Storage")
                            Spacer()
                            Picker("Storage view", selection: $storagePage) {
                                Text("Space usage").tag(StoragePage.usage)
                                Text("Disk activity").tag(StoragePage.activity)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        .padding(.bottom, 22)
                        if storagePage == .usage {
                            StorageCapacityBar(total: sample?.storageTotal, available: sample?.storageAvailable,
                                               tint: resource.tint, prominent: true)
                            Divider().padding(.vertical, 20)
                            StorageBreakdown(model: diskInventory, active: visibility.canScanStorage)
                        } else {
                            activity(size: area.size)
                        }
                    } else if resource == .power {
                        HStack {
                            pageTitle("Power")
                            Spacer()
                            Picker("Power view", selection: $powerPage) {
                                Text("Activity").tag(PowerPage.activity)
                                Text("Ports").tag(PowerPage.ports)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        .padding(.bottom, 20)
                        if powerPage == .ports {
                            PortPowerPanel(inputWatts: power.latest.inputWatts, active: visibility.isSampling,
                                           onBack: {}, expanded: true)
                        } else {
                            activity(size: area.size)
                        }
                    } else {
                        activity(size: area.size)
                    }
                }
                .padding(.horizontal, area.size.width < 420 ? 18 : 28)
                .padding(.vertical, 23)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(resource)
            .background {
                ZStack(alignment: .top) {
                    Color(nsColor: .controlBackgroundColor)
                    LinearGradient(colors: [resource.tint.opacity(colorScheme == .dark ? 0.085 : 0.045), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 144)
                }
            }
        }
    }

    private func pageTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.title2, design: .default, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            .layoutPriority(1)
    }

    private func activity(size: CGSize) -> some View {
        let compact = size.width < 430 || size.height < 480
        let chartHeight = min(compact ? 168.0 : 216.0, max(112.0, size.height * (compact ? 0.30 : 0.35)))
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                if resource == .storage || resource == .power {
                    Text(resource == .storage ? "Internal disk throughput" : resource.title)
                        .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                        .layoutPriority(1)
                } else {
                    pageTitle(resource.title)
                }
                Spacer(minLength: 8)
                MonitorRangePicker(selection: Binding(get: { duration }, set: { savedRange = $0 }), tint: resource.tint)
            }
            .padding(.bottom, compact ? 10 : 16)
            hero(compact: compact)
            let history = timeline
            let plot = series(history)
            MonitorChart(series: plot, end: end, duration: Double(duration), ceiling: ceiling(for: plot),
                         adaptiveCeiling: resource == .network || resource == .storage || resource == .power,
                         format: chartFormat)
                .frame(height: chartHeight)
                .padding(.top, compact ? 10 : 15)
            Divider().padding(.top, 14)
            if resource == .storage {
                StorageCapacityBar(total: sample?.storageTotal, available: sample?.storageAvailable, tint: resource.tint)
                    .padding(.top, 16)
            } else {
                statistics(history).padding(.top, 16)
            }
            if let metric = resource.appMetric {
                Divider().padding(.top, 17)
                DisclosureGroup(isExpanded: $showsApps) {
                    if showsApps {
                        MonitorApps(metric: metric, active: visibility.isSampling && !power.panelVisible, refreshInterval: refreshInterval)
                            .id(resource)
                            .padding(.top, 4)
                    }
                } label: {
                    HStack {
                        Text("Top apps and processes")
                        Spacer()
                        Text(metric == .cpu ? "100% = 1 core" : metric == .memory ? "Footprint" : "CPU power")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.callout.weight(.semibold))
                .padding(.top, 10)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorLiveIndicator(isSampling: visibility.isSampling, refreshInterval: refreshInterval, date: sample?.date)
                .padding(.leading, 8)
                .padding(.bottom, 11)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Resource.allCases) { resourceButton($0) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Divider().padding(.horizontal, 8).padding(.top, 6)
            Button {
                navigation.showsSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 35, alignment: .leading)
                    .background {
                        if navigation.showsSettings {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.08))
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(navigation.showsSettings ? .isSelected : [])
            .help("Wattline Settings (⌘,)")
            .padding(.vertical, 4)
            Text("\(coreCount) logical cores · \(MonitorFormat.memory(physicalMemory))")
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 12)
                .accessibilityLabel("This Mac, \(coreCount) logical CPU cores, \(MonitorFormat.memory(physicalMemory)) of RAM")
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 180, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    private func resourceButton(_ item: Resource) -> some View {
        let selected = item == resource && !navigation.showsSettings
        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                resource = item
                navigation.showsSettings = false
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? item.tint : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(item.rawValue).font(.body.weight(.semibold))
                        Spacer(minLength: 0)
                        sparkline(item)
                    }
                    Text(summary(item)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(item.tint.opacity(colorScheme == .dark ? 0.16 : 0.10))
                        .matchedGeometryEffect(id: "selection", in: selectionHighlight)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.rawValue)
        .accessibilityValue(summary(item))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func summary(_ item: Resource) -> String {
        switch item {
        case .cpu: MonitorFormat.percent(sample?.cpuPercent)
        case .memory: MonitorFormat.memory(sample?.memoryUsed)
        case .network: MonitorFormat.rate(sample?.downloadBytesPerSecond.map { $0 + (sample?.uploadBytesPerSecond ?? 0) })
        case .storage: MonitorFormat.rate(sample?.diskReadBytesPerSecond.map { $0 + (sample?.diskWriteBytesPerSecond ?? 0) })
        case .power: WattageFormat.detail(currentPower?.systemWatts)
        }
    }

    private func sparkline(_ item: Resource) -> some View {
        let recent = frames.suffix(24)
        let points: [(Date, Double?, Bool, TimeInterval)] = recent.map { frame in
            let value: Double?
            switch item {
            case .cpu: value = frame.system.cpuPercent
            case .memory: value = frame.system.memoryBytesForChart
            case .network:
                value = frame.system.downloadBytesPerSecond.flatMap { down in
                    frame.system.uploadBytesPerSecond.map { down + $0 }
                }
            case .storage: value = frame.system.diskReadBytesPerSecond.flatMap { read in frame.system.diskWriteBytesPerSecond.map { read + $0 } }
            case .power: value = frame.power?.systemWatts
            }
            return (frame.system.date, value, frame.resumes, frame.maximumGap)
        }
        return Canvas { context, size in
            guard let start = points.first?.0, let last = points.last?.0,
                  last.timeIntervalSince(start) >= 2, let peak = points.compactMap({ $0.1 }).max()
            else { return }
            var line = Path()
            var previous: Date?
            for (date, value, resumes, maximumGap) in points {
                guard let value else { previous = nil; continue }
                let x = date.timeIntervalSince(start) / last.timeIntervalSince(start) * (size.width - 2) + 1
                let y = size.height - 2 - (value / max(peak, 1)) * (size.height - 4)
                let p = CGPoint(x: x, y: y)
                if let previous, date.timeIntervalSince(previous) <= maximumGap, !resumes { line.addLine(to: p) }
                else { line.move(to: p) }
                previous = date
            }
            context.stroke(line, with: .color(item == resource ? item.tint : Color.secondary.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 31, height: 13)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func hero(compact: Bool) -> some View {
        if resource == .network || resource == .storage {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: compact ? 14 : 28) { throughputValues(large: !compact) }.fixedSize()
                HStack(spacing: 14) { throughputValues(large: false) }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary(resource))
                    .font(.system(size: compact ? 33 : 41, weight: .medium, design: .rounded).monospacedDigit())
                    .tracking(-1.5)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: summary(resource))
                HStack(spacing: 8) {
                    Text(heroCaption).foregroundStyle(.secondary)
                    if resource == .memory, let pressure = sample?.memoryPressure {
                        Text("·").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(pressure + " pressure")
                            .foregroundStyle(pressure == "Critical" ? Color.red : pressure == "Elevated" ? WattlineStyle.copper : Color.secondary)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func throughputValues(large: Bool) -> some View {
        ForEach([true, false], id: \.self) { down in
            let disk = resource == .storage
            let rate = disk
                ? (down ? sample?.diskReadBytesPerSecond : sample?.diskWriteBytesPerSecond)
                : (down ? sample?.downloadBytesPerSecond : sample?.uploadBytesPerSecond)
            VStack(alignment: .leading, spacing: 4) {
                Text(MonitorFormat.rate(rate))
                    .font(.system(size: large ? 32 : 22, weight: .medium, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: rate)
                Label(disk ? (down ? "Read" : "Write") : (down ? "Download" : "Upload"), systemImage: down ? "arrow.down" : "arrow.up")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(down ? resource.tint : secondaryTrace)
            }
        }
    }

    private var heroCaption: String {
        switch resource {
        case .cpu: sample?.cpuPercent == nil ? "Measuring CPU activity…" : "of total CPU capacity"
        case .memory: sample?.memoryTotal.map { "of " + MonitorFormat.memory($0) + " physical memory" } ?? "Physical memory"
        case .network, .storage: ""
        case .power: currentPower?.state.title ?? "Waiting for a power reading"
        }
    }

    private func series(_ timeline: [TimelineSample]) -> [MonitorSeries] {
        func data(_ title: String, _ color: Color, _ value: (HistorySample) -> Double?) -> MonitorSeries {
            MonitorSeries(title: title, color: color, timeline: timeline, value: value)
        }
        switch resource {
        case .cpu: return [data("CPU utilization", resource.tint) { $0.cpuPercent }]
        case .memory: return [data("Memory used", resource.tint) { $0.memoryUsed.map { Double($0) } }]
        case .network:
            return [data("Download", resource.tint) { $0.downloadBytesPerSecond },
                    data("Upload", secondaryTrace) { $0.uploadBytesPerSecond }]
        case .storage:
            return [data("Read", resource.tint) { $0.diskReadBytesPerSecond },
                    data("Write", secondaryTrace) { $0.diskWriteBytesPerSecond }]
        case .power: return [data("Mac power draw", resource.tint) { $0.systemWatts }]
        }
    }

    private func ceiling(for plot: [MonitorSeries]) -> Double {
        switch resource {
        case .cpu: return 100
        case .memory: return Double(sample?.memoryTotal ?? physicalMemory)
        case .network, .power, .storage:
            let peak = plot.flatMap { $0.points.compactMap(\.value) }.max() ?? 0
            guard peak > 0 else { return resource == .power ? 10 : 1000 }
            let factor = pow(10, floor(log10(peak)))
            let step = [1.0, 2, 5, 10].first(where: { $0 * factor >= peak }) ?? 10
            return step * factor
        }
    }

    private func chartFormat(_ value: Double) -> String {
        switch resource {
        case .cpu: MonitorFormat.percent(value)
        case .memory: MonitorFormat.memoryReading(value)
        case .network, .storage: MonitorFormat.rate(value)
        case .power: WattageFormat.detail(value)
        }
    }

    private func statistics(_ history: [TimelineSample]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            switch resource {
            case .cpu:
                stat("User", MonitorFormat.percent(sample?.cpuUserPercent))
                stat("System", MonitorFormat.percent(sample?.cpuSystemPercent))
                stat("Idle", MonitorFormat.percent(sample?.cpuPercent.map { 100 - $0 }))
            case .memory:
                stat("Wired", MonitorFormat.memory(sample?.memoryWired))
                stat("Compressed", MonitorFormat.memory(sample?.memoryCompressed))
                stat("Swap used", MonitorFormat.memory(sample?.swapUsed))
            case .network:
                stat("Peak download", MonitorFormat.rate(history.compactMap { $0.sample.downloadBytesPerSecond }.max()))
                stat("Peak upload", MonitorFormat.rate(history.compactMap { $0.sample.uploadBytesPerSecond }.max()))
                let links = sample?.networkLabels.joined(separator: ", ") ?? ""
                stat("Connection", links.isEmpty ? "—" : links)
                    .help("Active Wi-Fi and Ethernet interfaces: " + (sample?.networkInterfaces.joined(separator: ", ") ?? "—"))
            case .power:
                stat("Charger input", WattageFormat.detail(currentPower?.inputWatts))
                let flow = currentPower?.batteryWatts
                stat(flow.map { $0 < 0 ? "From battery" : "Into battery" } ?? "Battery flow", WattageFormat.detail(flow.map(abs)))
                stat("Charger limit", WattageFormat.detail(currentPower?.adapterWatts))
            case .storage: EmptyView()
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private actor MonitorAppSampler {
    private let sampler = EnergySampler()
    func read(_ metric: AppActivityMetric) -> [EnergyConsumer]? { sampler.sampleApps(metric) }
}

private struct MonitorApps: View {
    let metric: AppActivityMetric
    let active: Bool
    let refreshInterval: Int
    @State private var rows: [EnergyConsumer]?
    @State private var waiting = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let rows, !rows.isEmpty {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        ConsumerIcon(consumer: row).accessibilityHidden(true)
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        Text(value(row.value)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 24)
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text(waiting ? "Measuring…" : rows == nil ? "Process readings unavailable" : "No measurable activity")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(metric == .cpu ? "100% represents one CPU core." : metric == .memory
              ? "Memory footprint of readable processes, grouped by app." : "Estimated CPU power of readable processes, grouped by app.")
        .task(id: active ? refreshInterval : nil) {
            guard active else { return }
            let sampler = MonitorAppSampler()
            var first = true
            while !Task.isCancelled {
                let result = await sampler.read(metric)
                guard !Task.isCancelled else { return }
                rows = result
                waiting = first && result == nil
                first = false
                do { try await Task.sleep(for: .seconds(waiting ? refreshInterval : max(5, refreshInterval))) } catch { return }
            }
        }
    }

    private func value(_ amount: Double) -> String {
        switch metric {
        case .cpu: WattageFormat.cpuUsage(amount)
        case .memory: MonitorFormat.memoryReading(amount)
        case .power: WattageFormat.processPower(amount)
        }
    }
}
