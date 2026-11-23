import AppKit
import QuotaCore
import SwiftUI
import Testing
@testable import AIUsage

private let barWidth: CGFloat = 300, inset: CGFloat = 20

@MainActor
struct QuotaBarTests {
    enum Swatch: Sendable {
        case white, black, orange, red, track, background

        func matches(_ c: NSColor) -> Bool {
            let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
            switch self {
            case .white: return min(r, g, b) > 0.7
            case .black: return max(r, g, b) < 0.3
            case .orange: return r > 0.8 && (0.5...0.75).contains(g) && b < 0.3
            case .red: return r > 0.8 && g < 0.45 && b < 0.45
            // On the black backdrop of the dark scheme: the faint track, and the backdrop itself.
            case .track: return (0.03...0.2).contains(max(r, g, b))
            case .background: return max(r, g, b) < 0.02
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
        let pixel = try bar.color(x: inset + barWidth * testCase.remaining / 200)
        #expect(testCase.fill.matches(pixel), "fill pixel \(pixel)")
    }

    @Test(arguments: [0.0, 50, 100, -10, 150])
    func fillLengthIsTheRemainingShareOfTheTrack(remaining: Double) throws {
        let bar = try render(remaining: remaining, scheme: .dark)
        let filled = min(max(remaining, 0), 100) / 100
        for fraction in [0.05, 0.45, 0.55, 0.95] {
            let x = inset + barWidth * fraction, expected: Swatch = fraction < filled ? .white : .track
            // The bar is 6 pt high: 2 pt from its center is inside, 4.5 pt is outside.
            for dy in [-2.0, 0, 2] {
                let pixel = try bar.color(x: x, dy: dy)
                #expect(expected.matches(pixel), "at \(fraction) of the track, \(dy) pt: \(pixel)")
            }
            for dy in [-4.5, 4.5] {
                let pixel = try bar.color(x: x, dy: dy)
                #expect(Swatch.background.matches(pixel), "at \(fraction) of the track, \(dy) pt: \(pixel)")
            }
        }
        let pastTrack = try bar.color(x: inset + barWidth + inset / 2)
        #expect(Swatch.background.matches(pastTrack), "right of the track: \(pastTrack)")
    }

    @Test func fillStaysInsideTheRoundedEndOfTheTrack() throws {
        // At 1% the fill is 3 pt wide, and its rounded end is tighter than the track's.
        // 0.5 pt from the left and 1 pt from the top of the bar is inside that fill but outside the track.
        let bar = try render(remaining: 1, scheme: .dark, scale: 8)
        let pixel = try bar.color(x: inset + 0.5, dy: -2)
        #expect(Swatch.background.matches(pixel), "outside the track end: \(pixel)")
    }

    @Test func loadedBarFollowsAnAppearanceChange() throws {
        let host = NSHostingView(rootView: row(remaining: 50))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        for (appearance, fill) in [(NSAppearance.Name.darkAqua, Swatch.white), (.aqua, .black), (.darkAqua, .white)] {
            window.appearance = NSAppearance(named: appearance)
            // The view redraws asynchronously after the change; poll for up to 3 s.
            var pixel = NSColor.clear
            for _ in 0..<60 {
                RunLoop.main.run(until: .now + 0.05)
                pixel = try RenderedBar(layerOf: host).color(x: inset + barWidth / 4)
                if pixel.alphaComponent > 0.5 && fill.matches(pixel) { break }
            }
            #expect(pixel.alphaComponent > 0.5 && fill.matches(pixel), "\(appearance.rawValue): \(pixel)")
        }
    }

    private struct RenderedBar {
        let image: NSBitmapImageRep
        let scale: CGFloat
        let barCenterY: CGFloat

        init(_ image: CGImage, scale: CGFloat) {
            self.image = NSBitmapImageRep(cgImage: image)
            self.scale = scale
            // The 6 pt bar is the last element of the row, above the bottom inset.
            barCenterY = CGFloat(image.height) / scale - inset - 3
        }

        @MainActor
        init(layerOf view: NSView) throws {
            let scale: CGFloat = 2, size = view.bounds.size
            let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            let layer = try #require(view.layer)
            // render(in:) keeps the layer's top-down geometry; flip so that image row 0 is the top of the view.
            if layer.isGeometryFlipped {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            self.init(try #require(context.makeImage()), scale: scale)
        }

        func color(x: CGFloat, dy: CGFloat = 0) throws -> NSColor {
            let color = image.colorAt(x: Int(x * scale), y: Int((barCenterY + dy) * scale))
            return try #require(color?.usingColorSpace(.sRGB))
        }
    }

    private func row(remaining: Double) -> some View {
        let window = QuotaWindow(id: "weekly", title: "Weekly", remainingPercent: remaining, resetAt: nil)
        return QuotaWindowRow(window: window, now: .now)
            .frame(width: barWidth)
            .padding(inset)
    }

    private func render(remaining: Double, scheme: ColorScheme, scale: CGFloat = 2) throws -> RenderedBar {
        let renderer = ImageRenderer(content: row(remaining: remaining)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme))
        renderer.scale = scale
        return RenderedBar(try #require(renderer.cgImage), scale: scale)
    }
}
