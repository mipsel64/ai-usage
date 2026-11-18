import AppKit
import SwiftUI

enum UsagePanelColors {
    static let outer = dynamicColor(
        light: NSColor.underPageBackgroundColor,
        dark: NSColor(calibratedRed: 0.035, green: 0.043, blue: 0.052, alpha: 1)
    )
    static let sidebar = dynamicColor(
        light: NSColor.controlBackgroundColor,
        dark: NSColor(calibratedRed: 0.047, green: 0.055, blue: 0.067, alpha: 1)
    )
    static let card = dynamicColor(
        light: NSColor.controlBackgroundColor,
        dark: NSColor(calibratedRed: 0.078, green: 0.090, blue: 0.105, alpha: 1)
    )
    static let border = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.12),
        dark: NSColor.white.withAlphaComponent(0.16)
    )

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
