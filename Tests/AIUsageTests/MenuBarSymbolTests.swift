import AppKit
import Testing
@testable import AIUsage

@MainActor
struct MenuBarSymbolTests {
    @Test(arguments: [1, 2])
    func iconIsAFilledDiscWithTheGaugeCutOut(scale: Int) throws {
        let gauge = try #require(NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: menuBarSymbolPointSize, weight: .regular)))
        let icon = AIUsageApp.menuBarSymbol
        #expect(icon.isTemplate)

        let before = bitmap(gauge, scale: scale), after = bitmap(icon, scale: scale)
        var face: [String] = [], disc: [String] = [], edge: [String] = []
        for y in 0..<before.pixelsHigh {
            for x in 0..<before.pixelsWide {
                let dx = Double(x) + 0.5 - Double(before.pixelsWide) / 2, dy = Double(y) + 0.5 - Double(before.pixelsHigh) / 2
                let radius = (dx * dx + dy * dy).squareRoot() / Double(before.pixelsWide)
                let old = before.colorAt(x: x, y: y)!.alphaComponent, new = after.colorAt(x: x, y: y)!.alphaComponent
                // Dots and needle are inside 0.26 of the width; the ring is 0.34–0.41.
                if radius < 0.26, abs(new - (1 - old)) > 0.05 { face.append("\(x),\(y)") }
                if (0.31...0.37).contains(radius), new < 0.95 { disc.append("\(x),\(y)") }
                if radius > 0.40, abs(new - old) > 0.05 { edge.append("\(x),\(y)") }
            }
        }
        #expect(face.isEmpty, "face pixels not inverted: \(face)")
        #expect(disc.isEmpty, "disc pixels not filled: \(disc)")
        #expect(edge.isEmpty, "ring edge or outside pixels changed: \(edge)")
    }

    private func bitmap(_ image: NSImage, scale: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale, pixelsHigh: Int(image.size.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
