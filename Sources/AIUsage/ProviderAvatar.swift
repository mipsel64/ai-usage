import AppKit
import QuotaCore
import SwiftUI

@MainActor
private enum ProviderIconCache {
    private static var images: [ProviderID: NSImage] = [:]

    static func image(for id: ProviderID) -> NSImage? {
        if let cached = images[id] { return cached }
        let name = switch id {
        case .claude: "claude"
        case .codex: "codex"
        case .zai: "zai"
        case .kimi: "kimi"
        default: ""
        }
        guard !name.isEmpty,
              let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "ProviderIcons"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = id != .zai
        images[id] = image
        return image
    }
}

@MainActor
struct ProviderAvatar: View {
    let provider: QuotaProvider
    var size: CGFloat = 34

    private var accent: Color { UsageVisuals.accent(for: provider.id) }

    var body: some View {
        Group {
            if let icon = ProviderIconCache.image(for: provider.id) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.68, height: size * 0.68)
                    .foregroundStyle(provider.id == .codex ? .primary : accent)
            } else {
                Image(systemName: UsageVisuals.symbol(for: provider.id))
                    .font(.system(size: size * 0.40, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: size, height: size)
        .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .accessibilityHidden(true)
    }
}
