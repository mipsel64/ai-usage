import QuotaCore
import SwiftUI

@MainActor
struct ProviderCardHeader: View {
    let provider: QuotaProvider
    let state: ProviderState?
    let now: Date
    let isConnecting: Bool
    let canRedeem: Bool
    let onConnect: () -> Void
    let onRefresh: () -> Void
    let onShowAccounts: () -> Void
    let onRedeem: () -> Void

    private var isConnected: Bool { state?.connected == true }
    private var needsAuthentication: Bool { state?.needsAuthentication == true }

    var body: some View {
        HStack(spacing: 8) {
            ProviderAvatar(provider: provider, size: 22)
            Text(provider.displayName)
                .font(.headline)
                .lineLimit(1)
            if let credits = state?.snapshot?.resetCredits, credits.availableCount > 0 {
                ResetCreditsBadge(count: credits.availableCount)
            }
            ProviderStatusLabel(state: state, now: now)
            Spacer(minLength: 4)
            trailingControl
        }
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isConnecting || state?.loading == true {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
                .accessibilityLabel("\(provider.displayName) activity in progress")
        } else if isConnected && !needsAuthentication {
            ProviderActionsMenu(
                provider: provider,
                canRedeem: canRedeem,
                onRefresh: onRefresh,
                onShowAccounts: onShowAccounts,
                onRedeem: onRedeem
            )
        } else if needsAuthentication {
            Button("Sign In", action: onConnect)
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(.blue, in: .capsule)
                .controlSize(.small)
                .accessibilityLabel("Sign in to \(provider.displayName)")
        } else {
            Button("Connect", action: onConnect)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Connect \(provider.displayName)")
        }
    }
}
