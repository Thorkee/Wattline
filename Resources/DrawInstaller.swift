import AppKit
import ImageIO
import UniformTypeIdentifiers

// The two TIFF representations share a point size, so Finder can select the display scale.
let size = CGSize(width: 480, height: 232)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func draw(scale: Int) -> CGImage {
    let context = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
                            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.setFillColor(NSColor(srgbRed: 0.976, green: 0.975, blue: 0.968, alpha: 1).cgColor)
    context.fill(CGRect(origin: .zero, size: size))

    let arrowY = size.height - 91
    context.setStrokeColor(NSColor(white: 0.56, alpha: 1).cgColor)
    context.setLineWidth(1.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 219, y: arrowY))
    context.addLine(to: CGPoint(x: 261, y: arrowY))
    context.move(to: CGPoint(x: 255, y: arrowY + 5))
    context.addLine(to: CGPoint(x: 261, y: arrowY))
    context.addLine(to: CGPoint(x: 255, y: arrowY - 5))
    context.strokePath()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let instruction = NSAttributedString(string: "Drag Wattline to Applications.", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .regular),
        .foregroundColor: NSColor(white: 0.36, alpha: 1)
    ])
    let textSize = instruction.size()
    instruction.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                 y: size.height - 190 - textSize.height / 2))
    return context.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    throw NSError(domain: "DrawInstaller", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Usage: swift Resources/DrawInstaller.swift OUTPUT.tiff"
    ])
}
let target = URL(fileURLWithPath: CommandLine.arguments[1])
guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.tiff.identifier as CFString, 2, nil) else {
    throw CocoaError(.fileWriteUnknown)
}
for scale in 1...2 {
    let dpi = 72 * scale
    let options: [CFString: Any] = [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFCompression: 5, kCGImagePropertyTIFFResolutionUnit: 2,
            kCGImagePropertyTIFFXResolution: dpi, kCGImagePropertyTIFFYResolution: dpi
        ]
    ]
    CGImageDestinationAddImage(destination, draw(scale: scale), options as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else {
    throw CocoaError(.fileWriteUnknown)
}
