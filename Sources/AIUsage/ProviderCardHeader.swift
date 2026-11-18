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
    private var hasConnectedStatus: Bool {
        guard isConnected, !needsAuthentication, state?.message?.isEmpty != false,
              let snapshot = state?.snapshot else { return false }
        return now.timeIntervalSince(snapshot.observedAt) < 5 * 60
    }

    var body: some View {
        HStack(spacing: 8) {
            ProviderAvatar(provider: provider, size: 22)
            Text(provider.displayName)
                .font(.headline)
                .lineLimit(1)
                .accessibilityValue(hasConnectedStatus ? "Connected" : "")
            if let credits = state?.snapshot?.resetCredits, credits.availableCount > 0 {
                ResetCreditsBadge(count: credits.availableCount)
            }
            ProviderStatusLabel(state: state, now: now)
            Spacer(minLength: 4)
            trailingControl
        }
        .frame(minHeight: 24)
    }

    private var activityIndicator: some View {
        ProgressView()
            .controlSize(.mini)
            .frame(width: 24, height: 24)
            .accessibilityLabel("\(provider.displayName) activity in progress")
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isConnecting {
            activityIndicator
        } else if needsAuthentication {
            Button("Sign In", action: onConnect)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel("Sign in to \(provider.displayName)")
        } else if !isConnected {
            Button("Connect", action: onConnect)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel("Connect \(provider.displayName)")
        } else if state?.loading == true {
            activityIndicator
        }
        ProviderActionsMenu(
            provider: provider,
            canRefresh: !isConnecting && isConnected && !needsAuthentication && state?.loading != true,
            canRedeem: !isConnecting && canRedeem,
            onRefresh: onRefresh,
            onShowAccounts: onShowAccounts,
            onRedeem: onRedeem
        )
    }
}
