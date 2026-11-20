import AppKit

/// The outer dial stays recognizable as the power state changes. On battery
/// its needle shows charge in five steps, from empty at left to full at right.
@MainActor
struct MenuBarMark: Hashable {
    private let state: PowerState
    private let batteryStep: Int?
    private static var cache: [Self: NSImage] = [:]

    init(state: PowerState, percent: Int?) {
        self.state = state
        batteryStep = state == .onBattery ? percent.map { (min(100, max(0, $0)) + 12) / 25 } : nil
    }

    var image: NSImage {
        if let existing = Self.cache[self] { return existing }
        let centerSymbol: String?
        switch state {
        case .charging: centerSymbol = "bolt.fill"
        case .pluggedDraining: centerSymbol = "arrow.down"
        case .holding: centerSymbol = "pause.fill"
        case .full: centerSymbol = "checkmark"
        case .acPower: centerSymbol = "powerplug.fill"
        case .ups: centerSymbol = "shield.lefthalf.filled"
        case .unknown: centerSymbol = "questionmark"
        case .onBattery: centerSymbol = nil
        }
        let symbol = centerSymbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        }
        let step = batteryStep
        let result = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let dial = NSBezierPath()
            dial.appendArc(withCenter: NSPoint(x: 9, y: 8.6), radius: 7.1, startAngle: -36, endAngle: 216)
            dial.lineWidth = 1.8
            dial.lineCapStyle = .round
            dial.stroke()

            if let symbol {
                let scale = min(9.8 / symbol.size.width, 10.6 / symbol.size.height)
                let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                let rect = NSRect(x: 9 - size.width / 2, y: 7.7 - size.height / 2,
                                  width: size.width, height: size.height)
                symbol.draw(in: rect)
            } else {
                let pivot = NSPoint(x: 9, y: 6.2)
                if let step {
                    let angle = (153 - 31.5 * CGFloat(step)) * .pi / 180
                    let needle = NSBezierPath()
                    needle.move(to: pivot)
                    needle.line(to: NSPoint(x: pivot.x + 5.4 * cos(angle), y: pivot.y + 5.4 * sin(angle)))
                    needle.lineWidth = 1.8
                    needle.lineCapStyle = .round
                    needle.stroke()
                }
                NSBezierPath(ovalIn: NSRect(x: pivot.x - 1.65, y: pivot.y - 1.65,
                                            width: 3.3, height: 3.3)).fill()
            }
            return true
        }
        result.isTemplate = true
        Self.cache[self] = result
        return result
    }
}
