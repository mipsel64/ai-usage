import QuotaCore
import SwiftUI

@MainActor
struct ProviderAccountHeader: View {
    let provider: QuotaProvider

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
        }
    }
}
