import AppKit
import SwiftUI

struct MonitorRangePicker: View {
    @Binding var selection: Int
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var focused: Int?
    @State private var hovered: Int?
    @Namespace private var highlight

    private static let ranges = WattlinePreferences.historyRanges

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 1) {
                ForEach(Self.ranges, id: \.seconds) { range in
                    let selected = selection == range.seconds
                    Button {
                        selection = range.seconds
                    } label: {
                        Text(range.short)
                            .font(.callout.weight(selected ? .semibold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(selected ? tint : Color.primary)
                            .frame(minWidth: 30, minHeight: 21)
                            .padding(.horizontal, 2)
                            .background {
                                if selected {
                                    Capsule()
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .overlay { Capsule().strokeBorder(tint.opacity(contrast == .increased ? 0.9 : 0.30)) }
                                        .matchedGeometryEffect(id: "rangeSelection", in: highlight)
                                } else if hovered == range.seconds {
                                    Capsule().fill(.primary.opacity(0.06))
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focused($focused, equals: range.seconds)
                    .onHover { inside in
                        if inside { hovered = range.seconds }
                        else if hovered == range.seconds { hovered = nil }
                    }
                    .help("Show \(range.full) of history")
                    .accessibilityLabel(range.full)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(.primary.opacity(0.055), in: Capsule())
            .overlay { Capsule().strokeBorder(.secondary.opacity(contrast == .increased ? 0.65 : 0.14)) }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selection)
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("History range")
            .fixedSize()

            Menu {
                Picker("History range", selection: $selection) {
                    ForEach(Self.ranges, id: \.seconds) { range in
                        Text(range.full).tag(range.seconds)
                    }
                }
            } label: {
                Label(Self.ranges.first { $0.seconds == selection }?.short ?? "Range",
                      systemImage: "clock")
                    .font(.callout.weight(.medium))
            }
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("History range")
            .accessibilityValue(Self.ranges.first { $0.seconds == selection }?.full ?? "")
        }
    }

    private func move(_ direction: Int) -> KeyPress.Result {
        guard let focused, let i = Self.ranges.firstIndex(where: { $0.seconds == focused }) else { return .ignored }
        let next = Self.ranges[(i + direction + Self.ranges.count) % Self.ranges.count].seconds
        selection = next
        self.focused = next
        return .handled
    }
}

struct MonitorLiveIndicator: View {
    let isSampling: Bool
    let refreshInterval: Int
    let date: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Wattline").font(.system(.headline, design: .rounded, weight: .semibold))
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(isSampling ? Color(nsColor: .systemGreen) : .secondary)
                        .symbolEffect(.pulse, value: isSampling && !reduceMotion ? date : nil)
                        .accessibilityHidden(true)
                    Text(isSampling ? "\(refreshInterval)-second updates" : "Paused")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct StorageCapacityBar: View {
    let total: UInt64?
    let available: UInt64?
    let tint: Color
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder var body: some View {
        if prominent, let total, total > 0, let available, available <= total {
            let used = total - available
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(tint.opacity(contrast == .increased ? 0.35 : 0.15), lineWidth: 5)
                    Circle().trim(from: 0, to: CGFloat(used) / CGFloat(total))
                        .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "internaldrive.fill")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(tint)
                }
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Startup disk · " + size(total))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(size(used) + " used")
                        .font(.system(.title, design: .rounded, weight: .semibold).monospacedDigit())
                }
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Available").font(.caption).foregroundStyle(.secondary)
                    Text(size(available)).font(.system(.headline, design: .rounded).monospacedDigit())
                }
            }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        } else {
            capacityBar
        }
    }

    private var capacityBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Startup disk").font(.body.weight(.semibold))
                Spacer(minLength: 4)
                if let total, total > 0 {
                    Text("\(size(total)) total")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let total, let available, total > 0, available <= total {
                let used = total - available
                let ratio = Double(used) / Double(total)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(contrast == .increased ? 0.32 : 0.16))
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * ratio)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.23), value: used)
                    .accessibilityHidden(true)
                }
                .frame(height: 6)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(size(used)) used").fontWeight(.medium)
                    Spacer(minLength: 4)
                    Text("\(size(available)) available").foregroundStyle(.secondary)
                }
                .monospacedDigit()
            } else {
                Text("Capacity unavailable").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func size(_ bytes: UInt64) -> String {
        if bytes == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
    }
}
