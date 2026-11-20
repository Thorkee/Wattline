import SwiftUI

struct WattlineSettings: View {
    let shortcutAvailable: Bool
    var reading: PowerReading? = nil
    @ObservedObject var health: WattlineHealthMonitor
    @AppStorage(WattlinePreferences.appearanceKey) private var appearance = "system"
    @AppStorage(WattlinePreferences.refreshKey) private var refreshSeconds = 2
    @AppStorage(WattlinePreferences.historyRangeKey) private var historySeconds = 3_600
    @AppStorage(WattlinePreferences.automaticStorageKey) private var automaticStorage = false
    @AppStorage(WattlinePreferences.healthAlertsKey) private var healthAlerts = false
    @AppStorage("showMenuWatts") private var showMenuWatts = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")
                    .font(.system(.title2, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                section("Appearance")
                settingRow("Color scheme") {
                    Picker("Color scheme", selection: Binding(get: { ["system", "light", "dark"].contains(appearance) ? appearance : "system" }, set: { appearance = $0 })) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Divider().padding(.top, 16)
                section("Menu bar")
                menuPreview.padding(.top, 10)
                preferenceSwitch("Show watts in menu bar", description: "Display Mac power draw beside the gauge.",
                                 isOn: $showMenuWatts)

                Divider().padding(.top, 16)
                section("Monitoring")
                settingRow("Live refresh interval") {
                    Picker("Live refresh interval", selection: Binding(get: { WattlinePreferences.refreshInterval(refreshSeconds) },
                                                                   set: { refreshSeconds = $0 })) {
                        ForEach([2, 5, 10], id: \.self) { seconds in
                            Text("\(seconds)s").tag(seconds).accessibilityLabel("\(seconds) seconds")
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                settingRow("Chart history") {
                    Picker("Chart history", selection: Binding(get: { WattlinePreferences.historyRange(historySeconds) },
                                                             set: { historySeconds = $0 })) {
                        ForEach(WattlinePreferences.historyRanges, id: \.seconds) { range in
                            Text(range.full).tag(range.seconds)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Divider().padding(.top, 16)
                section("Storage")
                preferenceSwitch("Scan on first visit", description: "When off, start scans manually in Space usage.",
                                 isOn: $automaticStorage)

                Divider().padding(.top, 16)
                section("Health")
                preferenceSwitch("Notify me about health warnings", description: "Send a macOS notification when a sustained issue needs attention.",
                                 isOn: $healthAlerts)
                if let note = health.deliveryNote {
                    Text(note)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                healthStatus.padding(.top, 12)

                Divider().padding(.top, 16)
                section("Keyboard")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        shortcutLabel.fixedSize()
                        Spacer(minLength: 0)
                        shortcutValue.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        shortcutLabel
                        shortcutValue
                    }
                }
                .padding(.top, 10)
                .accessibilityElement(children: .combine)
                Text("Click the menu bar gauge to open the quick power view.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 23)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 20)
    }

    private func settingRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text(title).font(.body.weight(.medium)).fixedSize()
                Spacer(minLength: 0)
                control().fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                control()
            }
        }
        .tint(WattlineStyle.copper)
        .padding(.top, 11)
    }

    private func preferenceSwitch(_ title: String, description: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(description)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(WattlineStyle.copper)
        .padding(.top, 11)
        .accessibilityLabel(title)
        .accessibilityHint(description)
    }

    @ViewBuilder private var healthStatus: some View {
        if health.active.isEmpty {
            Label("No current warnings", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(health.active, id: \.id) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(WattlineStyle.copper)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.title).font(.callout.weight(.semibold))
                            Text(issue.message).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var menuPreview: some View {
        HStack(spacing: 12) {
            Text("Preview")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(nsImage: MenuBarMark(state: reading?.state ?? .unknown, percent: reading?.percent).image)
                    .renderingMode(.template)
                if showMenuWatts {
                    Text(WattageFormat.menuDraw(reading?.systemWatts) ?? "—")
                        .font(.callout.weight(.medium).monospacedDigit())
                }
            }
            if let date = reading?.date {
                Divider().frame(height: 14)
                Text(date, format: .dateTime.hour().minute())
                    .font(.callout.monospacedDigit())
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 44)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [WattlineStyle.copper.opacity(0.11), .secondary.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.secondary.opacity(contrast == .increased ? 0.55 : 0.18))
                }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: showMenuWatts)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar preview")
        .accessibilityValue(showMenuWatts
                            ? "Gauge and \(WattageFormat.menuDraw(reading?.systemWatts) ?? "unavailable power reading")"
                            : "Gauge only")
    }

    private var shortcutLabel: some View {
        Text("Show or hide quick power view")
            .font(.body.weight(.medium))
    }

    @ViewBuilder private var shortcutValue: some View {
        if shortcutAvailable {
            HStack(spacing: 3) {
                ForEach(["⌃", "⌥", "⌘", "W"], id: \.self) { key in
                    Text(key)
                        .font(.system(.body, design: .rounded, weight: .medium))
                        .frame(minWidth: 23, minHeight: 23)
                        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.secondary.opacity(contrast == .increased ? 0.65 : 0.24))
                        }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Control Option Command W")
        } else {
            Text("Shortcut unavailable")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Click the Wattline menu bar gauge to open the quick power view.")
        }
    }
}
