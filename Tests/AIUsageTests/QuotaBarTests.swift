import AppKit
import QuotaCore
import SwiftUI
import Testing
@testable import AIUsage

private let barWidth: CGFloat = 300, inset: CGFloat = 20, renderScale: CGFloat = 2

@MainActor
struct QuotaBarTests {
    enum Swatch: Sendable {
        case white, black, orange, red, empty

        func matches(_ c: NSColor) -> Bool {
            let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
            switch self {
            case .white: return min(r, g, b) > 0.7
            case .black: return max(r, g, b) < 0.3
            case .orange: return r > 0.8 && (0.5...0.75).contains(g) && b < 0.3
            case .red: return r > 0.8 && g < 0.45 && b < 0.45
            // Track or background on the black backdrop of the dark scheme.
            case .empty: return max(r, g, b) < 0.2
            }
        }
    }

    struct ColorCase: Sendable, CustomTestStringConvertible {
        let remaining: Double
        let scheme: ColorScheme
        let fill: Swatch
        var testDescription: String { "\(remaining)% \(scheme)" }
    }

    @Test(arguments: [
        ColorCase(remaining: 50, scheme: .dark, fill: .white),
        ColorCase(remaining: 50, scheme: .light, fill: .black),
        ColorCase(remaining: 21, scheme: .dark, fill: .white),
        ColorCase(remaining: 20, scheme: .dark, fill: .orange),
        ColorCase(remaining: 6, scheme: .dark, fill: .orange),
        ColorCase(remaining: 5, scheme: .dark, fill: .red),
    ])
    func fillUsesTheQuotaColorForTheColorScheme(_ testCase: ColorCase) throws {
        let bar = try render(remaining: testCase.remaining, scheme: testCase.scheme)
        let pixel = try bar.color(atBarFraction: testCase.remaining / 200)
        #expect(testCase.fill.matches(pixel), "fill pixel \(pixel)")
    }

    @Test(arguments: [0.0, 50, 100, -10, 150])
    func fillLengthIsTheRemainingShareOfTheTrack(remaining: Double) throws {
        let bar = try render(remaining: remaining, scheme: .dark)
        let filled = min(max(remaining, 0), 100) / 100
        for fraction in [0.05, 0.45, 0.55, 0.95] {
            let pixel = try bar.color(atBarFraction: fraction)
            let expected: Swatch = fraction < filled ? .white : .empty
            #expect(expected.matches(pixel), "at \(fraction) of the track: \(pixel)")
        }
        let pastTrack = try bar.color(atPointX: inset + barWidth + inset / 2)
        #expect(Swatch.empty.matches(pastTrack), "right of the track: \(pastTrack)")
    }

    private struct RenderedBar {
        let image: NSBitmapImageRep
        let barCenterY: CGFloat

        func color(atBarFraction fraction: Double) throws -> NSColor {
            try color(atPointX: inset + barWidth * fraction)
        }

        func color(atPointX x: CGFloat) throws -> NSColor {
            let color = image.colorAt(x: Int(x * renderScale), y: Int(barCenterY * renderScale))
            return try #require(color?.usingColorSpace(.sRGB))
        }
    }

    private func render(remaining: Double, scheme: ColorScheme) throws -> RenderedBar {
        let window = QuotaWindow(id: "weekly", title: "Weekly", remainingPercent: remaining, resetAt: nil)
        let row = QuotaWindowRow(window: window, now: .now)
            .frame(width: barWidth)
            .padding(inset)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: row)
        renderer.scale = renderScale
        let image = try #require(renderer.cgImage)
        // The 6 pt bar is the last element of the row.
        let barCenterY = CGFloat(image.height) / renderScale - inset - 3
        return RenderedBar(image: NSBitmapImageRep(cgImage: image), barCenterY: barCenterY)
    }
}
