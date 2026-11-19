import QuotaCore
import SwiftUI

@MainActor
struct ProviderCardHeader: View {
    let provider: QuotaProvider
    let state: ProviderState?
    let now: Date
    let canRedeem: Bool
    let onRefresh: () -> Void
    let onShowPreferences: () -> Void
    let onRedeem: () -> Void

    private var hasConnectedStatus: Bool {
        guard state?.message?.isEmpty != false, let snapshot = state?.snapshot else { return false }
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
            if state?.loading == true {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("\(provider.displayName) activity in progress")
            }
            ProviderActionsMenu(
                provider: provider,
                canRefresh: state?.loading != true,
                canRedeem: canRedeem,
                onRefresh: onRefresh,
                onShowPreferences: onShowPreferences,
                onRedeem: onRedeem
            )
        }
        .frame(minHeight: 24)
    }
}
