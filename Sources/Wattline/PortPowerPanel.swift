import SwiftUI

struct PortPowerPanel: View {
    let inputWatts: Double?
    let active: Bool
    let onBack: () -> Void
    var expanded = false
    @State private var ports: [PortPower]?
    @State private var showsDisconnected = false
    @State private var showsExplanation = false
    @ScaledMetric(relativeTo: .body) private var listHeight: CGFloat = 192

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !expanded { compactHeader }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if let inputWatts {
                        Text(WattageFormat.detail(inputWatts))
                            .font(.system(size: 38, weight: .medium, design: .rounded).monospacedDigit())
                            .tracking(-1.2)
                    }
                    Label(inputWatts == nil ? "Charger input unavailable" : "Mac charger input", systemImage: "powerplug.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(WattlineStyle.gold)
                }
                .accessibilityElement(children: .combine)
                .padding(.vertical, 6)
            } else if let inputWatts {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Mac charger input").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(WattageFormat.detail(inputWatts))
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }

            Divider().padding(.vertical, 8)
            if let ports, !ports.isEmpty {
                let visible = ports.filter { $0.connected != false }
                let disconnected = ports.filter { $0.connected == false }
                if expanded {
                    portList(visible, disconnected)
                } else {
                    ViewThatFits(in: .vertical) {
                        portList(visible, disconnected).fixedSize(horizontal: false, vertical: true)
                        ScrollView { portList(visible, disconnected).padding(.trailing, 4) }
                            .frame(height: listHeight)
                    }
                    .frame(maxHeight: listHeight, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(ports == nil ? "Reading ports…" : "This Mac hasn’t reported its ports.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            if expanded { Color.clear.frame(height: 12) } else { Spacer(minLength: 8) }
            Divider()
            DisclosureGroup("About port readings", isExpanded: $showsExplanation) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Charger input is the total power entering your Mac. A limit is the maximum agreed for a connection. An offer is the most a charger or display makes available.")
                    Text("Port output measures power sent to an accessory or hub. A hub’s reading includes the devices it powers. Some ports don’t report output. An inline USB power meter can measure one connection directly.")
                }
                .font(expanded ? .callout : .caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 5)
            }
            .padding(.vertical, 9)
        }
        .font(.callout)
        .task(id: active) {
            guard active else { ports = nil; return }
            let reader = PortPower.Reader()
            while !Task.isCancelled {
                let snapshot = await reader.read()
                guard !Task.isCancelled else { return }
                ports = snapshot
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }

    private func portList(_ visible: [PortPower], _ disconnected: [PortPower]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visible) { port in
                if expanded {
                    expandedRow(port)
                    Divider()
                } else {
                    compactRow(port)
                }
            }
            if !disconnected.isEmpty {
                DisclosureGroup("Disconnected ports (\(disconnected.count))", isExpanded: $showsDisconnected) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(disconnected) { port in Text(port.label) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, expanded ? 10 : 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactHeader: some View {
        HStack {
            Button(action: onBack) {
                Label("Power details", systemImage: "chevron.left")
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Back to power details")
            Spacer()
            Text("Ports").font(.headline)
        }
    }

    private func compactRow(_ port: PortPower) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol(port))
                .font(.body.weight(.medium))
                .foregroundStyle(port.isPowerInput ? WattlineStyle.copper : Color.secondary)
                .frame(width: 18, height: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(port.label).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    if let output = port.outputWatts {
                        Text(WattageFormat.detail(output) + " out")
                            .monospacedDigit()
                            .accessibilityLabel("Port output, " + WattageFormat.detail(output))
                            .help("Power leaving the Mac through this port.")
                    } else if let capacity = capacity(port) {
                        Text(capacity)
                            .monospacedDigit()
                            .help(port.limitWatts != nil ? "Maximum power negotiated on this connection." : "Highest fixed USB Power Delivery option advertised by this source.")
                    }
                }
                Text(status(port))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if port.outputWatts != nil, let capacity = capacity(port) {
                    Text(capacity).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func expandedRow(_ port: PortPower) -> some View {
        HStack(spacing: 12) {
            let accent = port.isPowerInput || port.outputWatts != nil ? WattlineStyle.gold : Color.secondary
            Image(systemName: symbol(port))
                .font(.body.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 32, height: 32)
                .background(accent.opacity(0.10), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(port.label).font(.body.weight(.semibold))
                Text(status(port))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if port.outputWatts != nil, let capacity = capacity(port) {
                    Text(capacity).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if let watts = port.outputWatts ?? port.limitWatts ?? port.offeredWatts {
                let label = port.outputWatts != nil ? "Port output" : port.limitWatts != nil ? "Negotiated limit" : "Power offered"
                VStack(alignment: .trailing, spacing: 3) {
                    Text(port.outputWatts == nil ? watts.formatted(.number.precision(.fractionLength(0...1))) + " W" : WattageFormat.detail(watts))
                        .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ port: PortPower) -> String {
        if port.isPowerInput { return "bolt.fill" }
        if port.transports.contains("DisplayPort") || port.label.hasPrefix("HDMI") { return "display" }
        if port.label.hasPrefix("SD") { return "sdcard" }
        return "cable.connector"
    }

    private func capacity(_ port: PortPower) -> String? {
        guard let watts = port.limitWatts ?? port.offeredWatts else { return nil }
        let amount = watts.formatted(.number.precision(.fractionLength(0...1)))
        return amount + (port.limitWatts != nil ? " W limit" : " W offered")
    }

    private func status(_ port: PortPower) -> String {
        if port.isPowerInput { return (["Power input"] + port.transports).joined(separator: " · ") }
        if !port.transports.isEmpty { return port.transports.joined(separator: " · ") }
        return port.connected == true ? "Connected" : "Connection unknown"
    }
}
