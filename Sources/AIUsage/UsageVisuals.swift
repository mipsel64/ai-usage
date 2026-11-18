import AppKit
import QuotaCore
import SwiftUI

// Command Line Tools require the property wrapper instead of the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

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

enum UsageVisuals {
    static func accent(for provider: ProviderID) -> Color {
        switch provider {
        case .claude: Color(red: 0.82, green: 0.39, blue: 0.22)
        case .codex: Color(red: 0.10, green: 0.62, blue: 0.48)
        case .zai: Color(red: 0.20, green: 0.46, blue: 0.92)
        case .kimi: Color(red: 0.50, green: 0.38, blue: 0.86)
        default: .accentColor
        }
    }

    static func symbol(for provider: ProviderID) -> String {
        switch provider {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .zai: "bolt.fill"
        case .kimi: "moon.stars.fill"
        default: "circle.hexagongrid.fill"
        }
    }

    static func quotaColor(remaining: Double) -> Color {
        if remaining <= 5 { return .red }
        if remaining <= 20 { return .orange }
        return .green
    }
}

struct AIUsageAppIcon: View {
    var size: CGFloat = 42

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(.linearGradient(
                colors: [Color(red: 0.22, green: 0.76, blue: 0.72), Color(red: 0.16, green: 0.42, blue: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

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

struct ConnectionBadge: View {
    let title: String
    let status: Status

    enum Status {
        case connected, waiting, disconnected, attention

        var color: Color {
            switch self {
            case .connected: .green
            case .waiting: .blue
            case .disconnected: .secondary
            case .attention: .orange
            }
        }

        var symbol: String {
            switch self {
            case .connected: "checkmark.circle.fill"
            case .waiting: "clock.fill"
            case .disconnected: "circle"
            case .attention: "exclamationmark.circle.fill"
            }
        }
    }

    var body: some View {
        Label(title, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.color)
            .labelStyle(.titleAndIcon)
    }
}

struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint(shortcut.map { "Keyboard shortcut \($0)" } ?? "")
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(UsagePanelColors.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(UsagePanelColors.border, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        }
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }
}

struct AccountField: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
    }
}
