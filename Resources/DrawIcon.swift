import AppKit
import SwiftUI

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
            green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: alpha)
}

func drawIcon(points: Int, scale: Int) -> Data {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphics.cgContext
    let pixelScale = CGFloat(pixels) / 1024
    context.scaleBy(x: pixelScale, y: pixelScale)
    context.setShouldAntialias(true)

    let frame = CGRect(x: 94, y: 100, width: 836, height: 836)
    let tile = NSBezierPath(cgPath: RoundedRectangle(cornerRadius: 181, style: .continuous)
        .path(in: frame).cgPath)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -9 * pixelScale),
                      blur: 13 * pixelScale, color: color(0x101214, alpha: 0.35).cgColor)
    color(0x222528).setFill()
    tile.fill()
    context.restoreGState()

    NSGradient(starting: color(0x17191B), ending: color(0x454B4C))?
        .draw(in: tile, angle: 108)
    tile.lineWidth = 3
    color(0xA7B2AC, alpha: 0.34).setStroke()
    tile.stroke()

    // Optical weights follow the display size, including its Retina representation.
    let tiny = points == 16
    let compact = points <= 32
    let pivot = CGPoint(x: 512, y: 454)
    let radius: CGFloat = 296
    let lineWidth: CGFloat = tiny ? 73 : (compact ? 52 : 40)

    func dialPoint(at angle: CGFloat, radius: CGFloat) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: pivot.x + radius * cos(radians), y: pivot.y + radius * sin(radians))
    }

    func arc(from start: CGFloat, to end: CGFloat, color ink: NSColor) {
        let path = NSBezierPath()
        path.appendArc(withCenter: pivot, radius: radius, startAngle: start, endAngle: end)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        ink.setStroke()
        path.stroke()
    }

    let paper = color(0xE7E8DB)
    let amber = color(0xFFAB54)
    let pointerAngle: CGFloat = 40
    // Rounded ends need a wider gap when the entire icon spans sixteen points.
    let gap: CGFloat = tiny ? 13 : (compact ? 9 : 7)
    arc(from: pointerAngle + gap, to: 210, color: paper)
    arc(from: -30, to: pointerAngle - gap, color: amber)

    if !compact {
        let marks = NSBezierPath()
        for angle: CGFloat in [0, 90, 135, 180] {
            marks.move(to: dialPoint(at: angle, radius: radius - 44))
            marks.line(to: dialPoint(at: angle, radius: radius - 62))
        }
        marks.lineWidth = 7
        marks.lineCapStyle = .round
        color(0xCACFC8, alpha: 0.72).setStroke()
        marks.stroke()
    }

    // Draw the hand along its own axis. A broad heel and narrow tip keep the
    // counterweight and direction distinct even in the smallest representation.
    context.saveGState()
    context.translateBy(x: pivot.x, y: pivot.y)
    context.rotate(by: pointerAngle * .pi / 180)
    let shoulder: CGFloat = tiny ? 46 : (compact ? 36 : 29)
    let heel: CGFloat = tiny ? 87 : 98
    let tip: CGFloat = compact ? 254 : 270
    let hand = NSBezierPath()
    hand.move(to: CGPoint(x: tip, y: 0))
    hand.line(to: CGPoint(x: 0, y: shoulder))
    hand.line(to: CGPoint(x: -heel, y: shoulder * 0.65))
    hand.curve(to: CGPoint(x: -heel, y: -shoulder * 0.65),
               controlPoint1: CGPoint(x: -heel - 17, y: shoulder * 0.62),
               controlPoint2: CGPoint(x: -heel - 17, y: -shoulder * 0.62))
    hand.line(to: CGPoint(x: 0, y: -shoulder))
    hand.close()
    context.saveGState()
    if !compact {
        context.setShadow(offset: CGSize(width: 0, height: -4 * pixelScale),
                          blur: 7 * pixelScale, color: color(0x080A0B, alpha: 0.62).cgColor)
    }
    amber.setFill()
    hand.fill()
    context.restoreGState()
    if !compact {
        let facet = NSBezierPath()
        facet.move(to: CGPoint(x: 0, y: 0))
        facet.line(to: CGPoint(x: tip, y: 0))
        facet.line(to: CGPoint(x: 0, y: shoulder))
        facet.close()
        color(0xFFCD8F).setFill()
        facet.fill()
    }
    context.restoreGState()

    let hub: CGFloat = tiny ? 54 : (compact ? 43 : 41)
    let hubFrame = CGRect(x: pivot.x - hub, y: pivot.y - hub, width: hub * 2, height: hub * 2)
    let cap = NSBezierPath(ovalIn: hubFrame)
    if compact {
        amber.setFill()
        cap.fill()
    } else {
        NSGradient(starting: color(0xDD8136), ending: color(0xFFCB8A))?
            .draw(in: cap, angle: 105)
        let axle = NSBezierPath(ovalIn: hubFrame.insetBy(dx: 23, dy: 23))
        color(0x343A3B).setFill()
        axle.fill()
    }

    graphics.flushGraphics()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        let name = "icon_\(points)x\(points)\(suffix).png"
        try drawIcon(points: points, scale: scale).write(to: directory.appendingPathComponent(name))
    }
}
