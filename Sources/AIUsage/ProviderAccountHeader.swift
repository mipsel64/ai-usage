import QuotaCore
import SwiftUI

@MainActor
struct ProviderAccountHeader: View {
    let provider: QuotaProvider
    let accountHost: String
    let openAccountPage: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderAvatar(provider: provider, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("AI Usage monitors the quota windows and reset times of this subscription.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Usage Portal", systemImage: "arrow.up.right", action: openAccountPage)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .labelStyle(.titleAndIcon)
                .accessibilityHint("Opens \(accountHost) in your default browser.")
                .help("Opens \(accountHost) in your default browser.")
        }
    }
}
