import SwiftUI

struct MonitorPoint {
    let date: Date
    let value: Double?
    var maximumGap: TimeInterval = 6

    var allowedGap: TimeInterval {
        maximumGap.isFinite && maximumGap > 0 ? maximumGap : 6
    }

    func connects(to next: MonitorPoint) -> Bool {
        let interval = next.date.timeIntervalSince(date)
        return interval > 0 && interval <= max(allowedGap, next.allowedGap)
    }
}

struct MonitorSeries {
    let title: String
    let color: Color
    let points: [MonitorPoint]
}

extension MonitorSeries {
    init(title: String, color: Color, timeline: [TimelineSample], value: (HistorySample) -> Double?) {
        var points: [MonitorPoint] = []
        for entry in timeline {
            let sample = entry.sample
            let reading = value(sample)
            if entry.startsSegment && !points.isEmpty {
                points.append(MonitorPoint(date: sample.date, value: nil))
            }
            // A fresh live sampler has no rate on its first reading. A continuous
            // archive handoff still joins the surrounding measured rates at any cadence.
            if reading == nil && sample.startsSegment && !entry.startsSegment { continue }
            points.append(MonitorPoint(date: sample.date, value: reading, maximumGap: entry.maximumGap))
        }
        self.init(title: title, color: color, points: points)
    }
}

struct MonitorChartTimeline {
    struct Target {
        let date: Date
        var before: TimeInterval
        var after: TimeInterval
    }

    let targets: [Target]
    let dates: [Date]
    let start: Date
    let end: Date
    let partial: Bool
    let peak: Double?
    var span: TimeInterval { max(0, end.timeIntervalSince(start)) }

    init(series: [MonitorSeries], start: Date, end: Date) {
        var indexed: [Date: Target] = [:]
        var first: MonitorPoint?
        var peak: Double?
        for line in series {
            var previous: MonitorPoint?
            for point in line.points {
                guard let value = point.value, value.isFinite, value >= 0,
                      point.date >= start, point.date <= end else {
                    previous = nil
                    continue
                }
                if first.map({ point.date < $0.date }) ?? true { first = point }
                peak = max(peak ?? value, value)
                // Isolated samples have a small hit area. Extend it toward neighboring
                // samples only when there is a continuous segment between them.
                let radius = min(3, point.allowedGap / 2)
                var target = indexed[point.date] ?? Target(date: point.date, before: radius, after: radius)
                if let previous, previous.connects(to: point), var prior = indexed[previous.date] {
                    let half = point.date.timeIntervalSince(previous.date) / 2
                    prior.after = max(prior.after, half)
                    target.before = max(target.before, half)
                    indexed[prior.date] = prior
                }
                indexed[point.date] = target
                previous = point
            }
        }
        targets = indexed.values.sorted { $0.date < $1.date }
        dates = targets.map(\.date)
        self.peak = peak
        self.end = end
        if let first {
            // A full range may start between two samples. Keep its chosen clock
            // bounds when the missing prefix is within the expected cadence.
            let tolerance = min(first.allowedGap / 2, max(0, end.timeIntervalSince(start)) * 0.05)
            partial = first.date.timeIntervalSince(start) > tolerance
            self.start = partial ? first.date : start
        } else {
            partial = false
            self.start = start
        }
    }

    func position(of date: Date) -> Double {
        guard span > 0 else { return 1 }
        return date.timeIntervalSince(start) / span
    }

    func date(at position: Double) -> Date { start.addingTimeInterval(span * position) }

    func scaleCeiling(fallback: Double, adaptive: Bool) -> Double {
        let safeFallback = fallback.isFinite && fallback > 0 ? fallback : 1
        guard adaptive, let peak, peak > 0 else { return safeFallback }
        // Keep zero and every spike in view. Smaller increments avoid doubling
        // the plot ceiling simply because a transfer exceeds a round threshold.
        let magnitude = pow(10, floor(log10(peak)))
        let step = magnitude * (peak < 3 * magnitude ? 0.25 : 0.5)
        let limit = ceil(peak * 1.04 / step) * step
        return limit.isFinite && limit >= peak ? limit : peak
    }

    func nearest(to date: Date, hitTolerance: TimeInterval = 0) -> Date? {
        var low = 0
        var high = targets.count
        while low < high {
            let mid = low + (high - low) / 2
            if targets[mid].date < date { low = mid + 1 }
            else { high = mid }
        }
        let neighbors = targets[max(0, low - 1)..<min(targets.count, low + 1)]
        return neighbors.compactMap { target -> (Date, TimeInterval)? in
            let distance = date.timeIntervalSince(target.date)
            guard distance >= -max(target.before, hitTolerance) && distance <= max(target.after, hitTolerance) else { return nil }
            return (target.date, abs(distance))
        }.min { $0.1 < $1.1 }?.0
    }

    static func ticks(start: Date, end: Date, width: CGFloat, timeZone: TimeZone = .autoupdatingCurrent) -> [Date] {
        let span = end.timeIntervalSince(start)
        guard span > 0, span <= HistoryDatabase.retention else { return [] }
        let count = width < 345 ? 3.0 : width < 485 ? 4.0 : 5.0
        let steps: [Double] = [1, 2, 5, 10, 15, 20, 30, 60, 90, 120, 180, 300, 600, 900, 1200,
                               1800, 3600, 5400, 7200, 10800, 14400, 21600, 28800, 43200, 86400]
        let candidates = steps.filter { (3..<5).contains(span / $0) }
        let step = (candidates.isEmpty ? steps : candidates).min {
            abs(span / $0 - (count - 0.25)) < abs(span / $1 - (count - 0.25))
        } ?? span
        // Clock ticks stay on local wall time through both DST transitions and
        // in time zones whose offset includes a fraction of an hour.
        let offsets = Set([timeZone.secondsFromGMT(for: start), timeZone.secondsFromGMT(for: end)])
        var ticks: [Date] = []
        for offset in offsets {
            let first = ceil((start.timeIntervalSince1970 + Double(offset)) / step) * step - Double(offset)
            for t in stride(from: first, through: end.timeIntervalSince1970, by: step) {
                let tick = Date(timeIntervalSince1970: t)
                if timeZone.secondsFromGMT(for: tick) == offset { ticks.append(tick) }
            }
        }
        return ticks.sorted()
    }
}

struct MonitorChart: View {
    let series: [MonitorSeries]
    let end: Date
    let duration: TimeInterval
    let ceiling: Double
    let adaptiveCeiling: Bool
    let format: (Double) -> String

    private struct Hover {
        let fraction: Double
        let hitRadiusFraction: Double
    }
    @State private var hover: Hover?
    @State private var keyboardDate: Date?
    @FocusState private var focused: Bool

    private let gutter: CGFloat = 4
    private let timeline: MonitorChartTimeline
    private var span: TimeInterval { timeline.span }
    private var start: Date { timeline.start }
    private var top: Double { timeline.scaleCeiling(fallback: ceiling, adaptive: adaptiveCeiling) }

    init(series: [MonitorSeries], end: Date, duration: TimeInterval, ceiling: Double, adaptiveCeiling: Bool = false,
         format: @escaping (Double) -> String) {
        self.series = series
        self.end = end
        self.duration = duration
        self.ceiling = ceiling
        self.adaptiveCeiling = adaptiveCeiling
        self.format = format
        let span = duration.isFinite ? max(duration, 1) : 1
        timeline = MonitorChartTimeline(series: series, start: end.addingTimeInterval(-span), end: end)
    }

    var body: some View {
        let dates = timeline.dates
        let selection = selectedDate(in: dates)
        let values = selection.map { readings(at: $0) } ?? []
        VStack(alignment: .leading, spacing: 4) {
            plot(dates: dates, selection: selection, values: values)
            if let caption = coverageLabel {
                Text(caption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        .padding(4)
        .frame(minHeight: 62)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            if focused {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(WattlineStyle.copper.opacity(0.78), lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: focused) { _, focused in if !focused { keyboardDate = nil } }
        .onChange(of: series.map(\.title)) { _, _ in keyboardDate = nil; hover = nil }
        .onKeyPress(.leftArrow) { step(-1, dates: dates); return .handled }
        .onKeyPress(.rightArrow) { step(1, dates: dates); return .handled }
        .onKeyPress(.escape) { keyboardDate = nil; hover = nil; return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(series.map(\.title).joined(separator: ", ") + " history")
        .accessibilityValue(spokenValue(at: selection ?? dates.last))
        .accessibilityHint((coverageLabel.map { $0 + ". " } ?? "") + "From \(time(start, seconds: true)) to \(time(end, seconds: true)). Use the arrow keys to inspect readings.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1, dates: dates)
            case .decrement: step(-1, dates: dates)
            @unknown default: break
            }
        }
    }

    private typealias Reading = (title: String, color: Color, value: Double, seriesIndex: Int)

    private func plot(dates: [Date], selection: Date?, values: [Reading]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 7) {
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width - gutter * 2)
                    Canvas { context, size in
                        draw(in: context, size: size, selection: selection)
                    }
                    .overlay {
                        if dates.isEmpty {
                            Text("No readings in this range").font(.caption)
                                .padding(.vertical, 4).padding(.horizontal, 7)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: (selection ?? end) < start.addingTimeInterval(span / 2) ? .topTrailing : .topLeading) {
                        if let selection {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(time(selection, seconds: true))
                                    .font(.caption2).foregroundStyle(.secondary)
                                ForEach(values.indices, id: \.self) { index in
                                    HStack(spacing: 5) {
                                        Canvas { context, size in
                                            var path = Path()
                                            path.move(to: CGPoint(x: 1, y: size.height / 2))
                                            path.addLine(to: CGPoint(x: size.width - 1, y: size.height / 2))
                                            context.stroke(path, with: .color(values[index].color),
                                                           style: lineStyle(for: values[index].seriesIndex))
                                        }
                                        .frame(width: 18, height: 8)
                                        Text(values[index].title)
                                        Text(format(values[index].value)).fontWeight(.semibold)
                                    }
                                }
                            }
                            .font(.caption.monospacedDigit())
                            .padding(.vertical, 7).padding(.horizontal, 9)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                            .padding(4).allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let position):
                            hover = Hover(fraction: min(1, max(0, (position.x - gutter) / width)), hitRadiusFraction: 2 / width)
                            keyboardDate = nil
                        case .ended:
                            hover = nil
                        }
                    }
                }
                timeAxis.frame(height: 15)
            }
            VStack(alignment: .trailing, spacing: 0) {
                Text(format(top))
                Spacer(minLength: 0)
                Text(format(top / 2))
                Spacer(minLength: 0)
                Text(format(0))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.bottom, 22)
        }
    }

    private var coverageLabel: String? {
        guard timeline.partial, let first = timeline.dates.first else { return nil }
        if timeline.dates.count == 1 { return "One reading at " + time(first, seconds: true) }
        func interval(_ seconds: TimeInterval) -> String {
            let unit: Duration.UnitsFormatStyle.Unit = seconds < 60 ? .seconds : .minutes
            let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [unit]
            let whole = seconds < 60 ? floor(seconds) : floor(seconds / 60) * 60
            return Duration.seconds(whole).formatted(.units(allowed: units, width: .abbreviated))
        }
        return interval(span) + " shown of " + interval(duration)
    }

    private func isVisible(_ point: MonitorPoint) -> Bool {
        guard let value = point.value, value.isFinite, value >= 0 else { return false }
        return point.date >= start && point.date <= end
    }

    private func selectedDate(in dates: [Date]) -> Date? {
        if let hover {
            if span == 0 && 1 - hover.fraction > hover.hitRadiusFraction { return nil }
            let target = timeline.date(at: hover.fraction)
            return timeline.nearest(to: target, hitTolerance: span * hover.hitRadiusFraction)
        }
        if let keyboardDate, dates.contains(keyboardDate) { return keyboardDate }
        return nil
    }

    private func step(_ direction: Int, dates: [Date]) {
        guard !dates.isEmpty else { return }
        let current = selectedDate(in: dates)
        hover = nil
        if let current, let index = dates.firstIndex(of: current) {
            keyboardDate = dates[max(0, min(dates.count - 1, index + direction))]
        } else {
            keyboardDate = direction < 0 ? dates.last : dates.first
        }
    }

    private func time(_ date: Date, seconds: Bool) -> String {
        if span >= 43_200 && seconds {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
        }
        if seconds { return date.formatted(.dateTime.hour().minute().second()) }
        return date.formatted(.dateTime.hour().minute())
    }

    private var timeAxis: some View {
        Canvas { context, size in
            let ticks = span < 1 ? [end] : MonitorChartTimeline.ticks(start: start, end: end, width: size.width)
            let width = max(1, size.width - gutter * 2)
            var lastLabelEnd = -CGFloat.infinity
            let calendar = Calendar.autoupdatingCurrent
            let showsSeconds = span < 180 || ticks.contains { calendar.component(.second, from: $0) != 0 }
            for tick in ticks {
                let clock = calendar.dateComponents([.hour, .minute, .second], from: tick)
                let isMidnight = clock.hour == 0 && clock.minute == 0 && clock.second == 0
                let label = isMidnight && span >= 43_200
                    ? tick.formatted(.dateTime.month(.abbreviated).day())
                    : time(tick, seconds: showsSeconds)
                let text = context.resolve(Text(verbatim: label).font(.caption2.monospacedDigit()))
                let measured = text.measure(in: size)
                let tickX = gutter + width * timeline.position(of: tick)
                let labelX = max(measured.width / 2, min(size.width - measured.width / 2, tickX))
                guard labelX - measured.width / 2 >= lastLabelEnd + 3 else { continue }
                context.draw(text, at: CGPoint(x: labelX, y: size.height / 2), anchor: .center)
                lastLabelEnd = labelX + measured.width / 2
            }
        }
    }

    private func readings(at date: Date) -> [Reading] {
        series.enumerated().compactMap { index, line in
            guard let point = line.points.last(where: { $0.date == date && isVisible($0) }),
                  let value = point.value else { return nil }
            return (line.title, line.color, value, index)
        }
    }

    private func lineStyle(for seriesIndex: Int) -> StrokeStyle {
        StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: seriesIndex == 1 ? [5, 3] : [])
    }

    static func displayPoints(_ points: [CGPoint], width: CGFloat) -> [CGPoint] {
        guard CGFloat(points.count) > width * 3, let first = points.first, let last = points.last else { return points }
        var reduced = [first]
        var column = first.x.rounded(.down)
        var low = 0
        var high = 0
        func appendExtremes() {
            let earlier = min(low, high), later = max(low, high)
            if reduced.last != points[earlier] { reduced.append(points[earlier]) }
            if later != earlier { reduced.append(points[later]) }
        }
        for (i, point) in points.enumerated() {
            let x = point.x.rounded(.down)
            if x != column {
                appendExtremes()
                column = x
                low = i
                high = i
            } else {
                if point.y < points[low].y { low = i }
                if point.y > points[high].y { high = i }
            }
        }
        appendExtremes()
        if reduced.last != last { reduced.append(last) }
        return reduced
    }

    private func spokenValue(at date: Date?) -> String {
        guard let date else { return "No readings yet" }
        return ([time(date, seconds: true)] + readings(at: date).map { $0.title + " " + format($0.value) })
            .joined(separator: ", ")
    }

    private func draw(in context: GraphicsContext, size: CGSize, selection: Date?) {
        let width = max(1, size.width - gutter * 2)
        let height = max(1, size.height - gutter * 2)
        let baseline = height + gutter
        let yMaximum = top
        func x(_ date: Date) -> CGFloat { gutter + width * timeline.position(of: date) }
        func y(_ value: Double) -> CGFloat { baseline - height * min(1, value / yMaximum) }
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            var grid = Path()
            grid.move(to: CGPoint(x: gutter, y: gutter + fraction * height))
            grid.addLine(to: CGPoint(x: width + gutter, y: gutter + fraction * height))
            let opacity = fraction == 1 ? 0.35 : 0.21
            context.stroke(grid, with: .color(.secondary.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 0.65, dash: fraction == 1 ? [] : [2, 4]))
        }

        if let selection {
            var rule = Path()
            rule.move(to: CGPoint(x: x(selection), y: gutter))
            rule.addLine(to: CGPoint(x: x(selection), y: baseline))
            context.stroke(rule, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        for (index, line) in series.enumerated() {
            var segment: [CGPoint] = []
            var previous: MonitorPoint?
            var selectedPoint: CGPoint?
            func dot(_ center: CGPoint, radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            func flush() {
                guard let first = segment.first, let last = segment.last else { return }
                if segment.count == 1 {
                    context.fill(dot(first, radius: 1.8), with: .color(line.color))
                } else {
                    var trace = Path()
                    trace.addLines(Self.displayPoints(segment, width: width))
                    var fill = trace
                    fill.addLine(to: CGPoint(x: last.x, y: baseline))
                    fill.addLine(to: CGPoint(x: first.x, y: baseline))
                    fill.closeSubpath()
                    context.fill(fill, with: .linearGradient(
                        Gradient(colors: [line.color.opacity(0.16), line.color.opacity(0.015)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: baseline)))
                    context.stroke(trace, with: .color(line.color), style: lineStyle(for: index))
                }
                segment.removeAll(keepingCapacity: true)
            }
            for point in line.points {
                guard let value = point.value, isVisible(point) else { flush(); previous = nil; continue }
                if let previous, !previous.connects(to: point) { flush() }
                let location = CGPoint(x: x(point.date), y: y(value))
                segment.append(location)
                if point.date == selection { selectedPoint = location }
                previous = point
            }
            let last = segment.last
            flush()
            if let selectedPoint {
                context.fill(dot(selectedPoint, radius: 3.6), with: .color(line.color))
            } else if selection == nil, let last, let previous,
                      end.timeIntervalSince(previous.date) <= previous.allowedGap {
                context.fill(dot(last, radius: 2.7), with: .color(line.color))
            }
        }
    }
}
