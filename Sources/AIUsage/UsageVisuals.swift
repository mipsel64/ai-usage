import QuotaCore
import SwiftUI

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
