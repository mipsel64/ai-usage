import QuotaCore
import SwiftUI

struct ProviderActionsMenu: View {
    let provider: QuotaProvider
    let canRedeem: Bool
    let onRefresh: () -> Void
    let onShowAccounts: () -> Void
    let onRedeem: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu("\(provider.displayName) actions", systemImage: "ellipsis") {
            Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
            Button("Open Usage Portal", systemImage: "arrow.up.right", action: openUsagePortal)
            Button("Account Settings…", systemImage: "person.crop.circle", action: onShowAccounts)
            if provider.supportsBankedReset {
                Divider()
                Button("Redeem Banked Reset…", systemImage: "arrow.uturn.backward", action: onRedeem)
                    .disabled(!canRedeem)
                    .help("Review and redeem one eligible banked reset.")
            }
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24, height: 24)
        .accessibilityLabel("\(provider.displayName) actions")
    }

    private func openUsagePortal() {
        openURL(provider.resetURL ?? provider.accountURL)
    }
}
