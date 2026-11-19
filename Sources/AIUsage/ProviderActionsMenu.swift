import QuotaCore
import SwiftUI

struct ProviderActionsMenu: View {
    let provider: QuotaProvider
    let canRefresh: Bool
    let canRedeem: Bool
    let onRefresh: () -> Void
    let onShowPreferences: () -> Void
    let onRedeem: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu("\(provider.displayName) actions", systemImage: "ellipsis") {
            Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(!canRefresh)
            Button("Open Usage Portal", systemImage: "arrow.up.right", action: openUsagePortal)
            Button("Show in Preferences…", systemImage: "gearshape", action: onShowPreferences)
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
