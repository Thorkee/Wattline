import AppKit
import SwiftUI

struct PowerPanel: View {
    @ObservedObject var monitor: PowerMonitor
    let onOpenWattline: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    private enum Page { case overview, details, ports }
    @State private var page = Page.overview
    @ScaledMetric(relativeTo: .body) private var contentWidth: CGFloat = 280
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 242
    private var reading: PowerReading { monitor.latest }
    private var hasExternalSupply: Bool { reading.state == .acPower || reading.state == .ups }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CompactHealthNotice(health: monitor.health, openSettings: onSettings)
            switch page {
            case .overview: overview
            case .details: details
            case .ports: PortPowerPanel(inputWatts: reading.inputWatts, active: monitor.panelVisible, onBack: { page = .details })
            }
        }
        .frame(width: min(contentWidth, 408), alignment: .leading)
        .frame(minHeight: minimumHeight, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .background(.regularMaterial)
        .onDisappear { page = .overview }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourceHeader
            Divider().padding(.vertical, 13)

            ConsumersList(ranking: monitor.ranking)
            Spacer(minLength: 8)
            Divider()
            HStack(spacing: 12) {
                Button(action: onOpenWattline) {
                    Label("Open Wattline", systemImage: "macwindow")
                        .font(.callout.weight(.semibold))
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel("Open Wattline")
                Spacer(minLength: 4)
                Button {
                    page = .details
                } label: {
                    HStack(spacing: 5) {
                        Text("Power details")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var sourceHeader: some View {
        HStack(spacing: 10) {
            SourceDial(reading: reading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if let percent = reading.percent {
                    Text((Double(percent) / 100).formatted(.percent))
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit())
                        .tracking(-1)
                        .accessibilityLabel("Battery \((Double(percent) / 100).formatted(.percent))")
                }
                Text(reading.state.title)
                    .font(reading.percent == nil ? .headline : .callout)
                    .foregroundStyle(reading.percent == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(WattageFormat.detail(reading.systemWatts))
                    .font(.system(.title3, design: .rounded, weight: .medium).monospacedDigit())
                Text("Mac draw").font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mac power draw")
            .accessibilityValue(reading.systemWatts.map { WattageFormat.detail($0) } ?? "Unavailable")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    page = .overview
                } label: {
                    Label("Overview", systemImage: "chevron.left")
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to overview")
                Spacer()
                Button {
                    page = .ports
                } label: {
                    HStack(spacing: 4) {
                        Text("Ports")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Power by port")
            }
            HStack {
                Text("Mac draw")
                Spacer()
                Text(WattageFormat.detail(reading.systemWatts)).monospacedDigit()
            }
            .font(.system(.headline, design: .rounded))
            .padding(.top, 8)

            if monitor.history.contains(where: { validDraw($0.systemWatts) != nil }) {
                PowerHistory(samples: monitor.history, breaks: monitor.historyBreaks, end: reading.date)
                    .padding(.top, 6)
            } else {
                Text("No recent power readings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Divider().padding(.vertical, 6)
            Grid(alignment: .leading, verticalSpacing: 3) {
                if hasExternalSupply {
                    GridRow {
                        Text("Power source").foregroundStyle(.secondary)
                        Spacer()
                        Text(reading.state.title).gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                if reading.hasInternalBattery == true || reading.inputWatts != nil {
                    metric("Charger input", reading.inputWatts)
                }
                if reading.hasInternalBattery == true || reading.batteryWatts != nil {
                    metric(batteryFlowLabel, reading.batteryWatts.map(abs))
                }
                if reading.connected == true, reading.adapterWatts != nil {
                    metric("Connection limit", reading.adapterWatts)
                        .help("Maximum power negotiated with the charger.")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Divider()
            HStack {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                    Button {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    } label: {
                        HStack(spacing: 3) {
                            Text("Activity Monitor")
                            Image(systemName: "arrow.up.right").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Inspect more apps and processes in Activity Monitor.")
                }
                Spacer()
                Button("Quit Wattline", action: onQuit)
                    .buttonStyle(.plain)
                    .keyboardShortcut("q")
            }
            .frame(minHeight: 32)
            .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var batteryFlowLabel: String {
        guard let flow = reading.batteryWatts else { return "Battery flow" }
        if flow >= 0.05 { return "Into battery" }
        if flow <= -0.05 { return "From battery" }
        return "Battery flow"
    }

    private func metric(_ label: String, _ value: Double?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(WattageFormat.detail(value)).monospacedDigit().gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

}

private struct CompactHealthNotice: View {
    @ObservedObject var health: WattlineHealthMonitor
    let openSettings: () -> Void

    var body: some View {
        if let issue = health.active.first {
            Button(action: openSettings) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(WattlineStyle.copper)
                    Text(issue.title)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if health.active.count > 1 {
                        Text("+\(health.active.count - 1)").foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.callout.weight(.medium))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(issue.title)
            .accessibilityValue(health.active.count == 1 ? "1 active issue" : "\(health.active.count) active issues")
            .accessibilityHint("Opens diagnostics in Wattline Settings.")
            .help(issue.message)
            .padding(.bottom, 10)
        }
    }
}

private struct SourceDial: View {
    let reading: PowerReading
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 37

    var body: some View {
        ZStack {
            if let percent = reading.percent {
                // The scale starts at the lower left and ends at the lower right.
                Circle().trim(from: 0, to: 0.75)
                    .stroke(.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                if percent > 0 {
                    Circle().trim(from: 0, to: 0.75 * CGFloat(min(percent, 100)) / 100)
                        .stroke(WattlineStyle.copper, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(135))
                }
            }
            Image(systemName: reading.state.symbol)
                .font(.system(size: diameter * 0.43, weight: .semibold))
                .foregroundStyle(WattlineStyle.copper)
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct ConsumersList: View {
    let ranking: EnergyRanking?

    private var metricDescription: (title: String, help: String) {
        guard let ranking, ranking.isAvailable else {
            return ("App activity", "Measured for apps and processes while Wattline is open.")
        }
        switch ranking.metric {
        case .cpu: return ("Highest CPU usage", "Recent CPU usage for visible apps and processes. 100% represents one CPU core.")
        case .power: return ("Highest CPU power", "Estimated CPU power for apps and processes macOS lets Wattline measure.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(metricDescription.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .help(metricDescription.help)
                .padding(.bottom, 5)
            if let ranking {
                if !ranking.isAvailable {
                    placeholder("Process readings unavailable")
                } else if ranking.consumers.isEmpty {
                    placeholder("No measurable activity")
                } else {
                    ForEach(ranking.consumers.prefix(3)) { consumer in
                        HStack(spacing: 9) {
                            ConsumerIcon(consumer: consumer)
                                .accessibilityHidden(true)
                            Text(consumer.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(consumer.bundlePath == nil ? consumer.id : consumer.name)
                            Spacer(minLength: 6)
                            Text(valueText(consumer.value, metric: ranking.metric))
                                .monospacedDigit()
                                .font(.callout.weight(.medium))
                        }
                        .frame(minHeight: 30)
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                placeholder("Measuring…")
            }
        }
        .font(.body)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(minHeight: 25)
    }

    private func valueText(_ value: Double, metric: EnergyMetric) -> String {
        switch metric {
        case .power:
            return WattageFormat.processPower(value)
        case .cpu:
            return WattageFormat.cpuUsage(value)
        }
    }
}

struct ConsumerIcon: View {
    let consumer: EnergyConsumer

    var body: some View {
        Group {
            if let path = consumer.bundlePath {
                NativeAppIcon(path: path)
                    .id(path)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.secondary.opacity(0.12))
                    Image(systemName: serviceSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 20, height: 20)
            }
        }
        .frame(width: 24, height: 24)
    }

    private var serviceSymbol: String {
        switch URL(fileURLWithPath: consumer.id).lastPathComponent {
        case "com.apple.Virtualization.VirtualMachine": "desktopcomputer"
        case "cfprefsd": "slider.horizontal.3"
        case "mds", "mdworker", "mdworker_shared", "mds_stores": "magnifyingglass"
        case "WindowServer": "macwindow.on.rectangle"
        default: "terminal"
        }
    }
}

private struct NativeAppIcon: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let workspace = NSWorkspace.shared
        let bundle = Bundle(path: path)
        let source: String
        // The bundled Claude Code CLI ships without artwork. Its installed
        // desktop companion provides the native Claude icon when available.
        if bundle?.bundleIdentifier == "com.anthropic.claude-code",
           bundle?.object(forInfoDictionaryKey: "CFBundleIconName") == nil,
           bundle?.object(forInfoDictionaryKey: "CFBundleIconFile") == nil,
           let desktop = workspace.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            source = desktop.path
        } else {
            source = path
        }
        let icon = workspace.icon(forFile: source).copy() as? NSImage
        icon?.size = NSSize(width: 24, height: 24)
        icon?.isTemplate = false
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        // AppKit selects the native icon representation for the current
        // backing scale and appearance, including when changing displays.
        view.image = icon
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

private func validDraw(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0 else { return nil }
    return value
}

private struct PowerHistory: View {
    let samples: [PowerReading]
    let breaks: Set<Date>
    let end: Date
    private let limit: TimeInterval = 15 * 60
    private let maxGap: TimeInterval = 12

    var body: some View {
        let start = max(end.addingTimeInterval(-limit), samples.first?.date ?? end)
        let span = max(end.timeIntervalSince(start), 0)
        let window = samples.filter { $0.date >= start && $0.date <= end }
        let peak = window.compactMap { validDraw($0.systemWatts) }.max()
        let ceiling = max(10, ceil((peak ?? 0) / 10) * 10)

        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                Canvas { context, size in
                    let inset: CGFloat = 3.5
                    let width = size.width - inset * 2
                    let height = size.height - inset * 2
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = inset + fraction * height
                        var grid = Path()
                        grid.move(to: CGPoint(x: inset, y: y))
                        grid.addLine(to: CGPoint(x: size.width - inset, y: y))
                        context.stroke(grid, with: .color(.secondary.opacity(0.23)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 4]))
                    }

                    var segment: [CGPoint] = []
                    func drawSegment() {
                        guard let first = segment.first, let last = segment.last else { return }
                        if segment.count == 1 {
                            let dot = CGRect(x: first.x - 1.7, y: first.y - 1.7, width: 3.4, height: 3.4)
                            context.fill(Path(ellipseIn: dot), with: .color(WattlineStyle.copper))
                        } else {
                            var trace = Path()
                            trace.addLines(segment)
                            var shade = trace
                            shade.addLine(to: CGPoint(x: last.x, y: height + inset))
                            shade.addLine(to: CGPoint(x: first.x, y: height + inset))
                            shade.closeSubpath()
                            context.fill(shade, with: .color(WattlineStyle.copper.opacity(0.08)))
                            context.stroke(trace, with: .color(WattlineStyle.copper), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        }
                        segment.removeAll(keepingCapacity: true)
                    }

                    var previousDate: Date?
                    for sample in window {
                        guard let watts = validDraw(sample.systemWatts) else {
                            drawSegment()
                            previousDate = nil
                            continue
                        }
                        if breaks.contains(sample.date) || previousDate.map({ sample.date <= $0 || sample.date.timeIntervalSince($0) > maxGap }) == true {
                            drawSegment()
                        }
                        let x = span > 0 ? sample.date.timeIntervalSince(start) / span : 1
                        segment.append(CGPoint(x: inset + width * x, y: inset + height * (1 - watts / ceiling)))
                        previousDate = sample.date
                    }
                    let endpoint = segment.last
                    drawSegment()
                    if let endpoint {
                        let dot = CGRect(x: endpoint.x - 2.6, y: endpoint.y - 2.6, width: 5.2, height: 5.2)
                        context.fill(Path(ellipseIn: dot), with: .color(WattlineStyle.copper))
                    }
                }
                .frame(height: 42)

                HStack {
                    if span >= 1 { Text(relativeLabel(span)) }
                    Spacer()
                    Text("Now")
                }
            }
            VStack(alignment: .trailing) {
                Text(peak == nil ? "—" : WattageFormat.menuDraw(ceiling) ?? "—")
                Spacer()
                Text("0")
            }
            .frame(height: 44)
        }
        .foregroundStyle(.secondary)
        .font(.caption2.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent Mac power draw")
        .accessibilityValue(peak.map { "Peak \(WattageFormat.detail($0))" } ?? "No readings available")
    }

    private func relativeLabel(_ span: TimeInterval) -> String {
        if span >= 60 { return "\(Int(span / 60)) min ago" }
        return "\(Int(span)) sec ago"
    }
}
