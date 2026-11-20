import AppKit
import SwiftUI

enum WattlineStyle {
    static let copper = adaptive(light: 0x974D14, dark: 0xFFB061)
    static let jade = adaptive(light: 0x146A61, dark: 0x78D6C8)
    static let iris = adaptive(light: 0x685392, dark: 0xC4A9EB)
    static let marine = adaptive(light: 0x2F6691, dark: 0x88C3EF)
    static let gold = adaptive(light: 0x866213, dark: 0xECCA7A)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}
