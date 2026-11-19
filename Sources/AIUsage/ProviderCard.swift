import QuotaCore
import SwiftUI

@MainActor
struct ProviderCard: View {
    let provider: QuotaProvider
    let state: ProviderState?
    let now: Date
    let canRedeem: Bool
    let resetResult: String?
    let resetError: String?
    let onRefresh: () -> Void
    let onShowPreferences: () -> Void
    let onRedeem: () -> Void

    private var hasBody: Bool {
        state?.snapshot != nil || state?.message?.isEmpty == false ||
            resetResult?.isEmpty == false || resetError?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ProviderCardHeader(
                provider: provider,
                state: state,
                now: now,
                canRedeem: canRedeem,
                onRefresh: onRefresh,
                onShowPreferences: onShowPreferences,
                onRedeem: onRedeem
            )
            if hasBody {
                ProviderCardBody(
                    provider: provider,
                    state: state,
                    now: now,
                    resetResult: resetResult,
                    resetError: resetError
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, hasBody ? 13 : 9)
        .background(.quaternary, in: .rect(cornerRadius: 16))
    }
}
