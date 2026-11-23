import QuotaCore
import SwiftUI

struct ProviderActionsMenu: View {
    let provider: QuotaProvider
    let canRefresh: Bool
    let onRefresh: () -> Void
    let onShowPreferences: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu("\(provider.displayName) actions", systemImage: "ellipsis") {
            Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                .disabled(!canRefresh)
            Button("Open Usage Portal", systemImage: "arrow.up.right", action: openUsagePortal)
            Button("Show in Preferences…", systemImage: "gearshape", action: onShowPreferences)
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
