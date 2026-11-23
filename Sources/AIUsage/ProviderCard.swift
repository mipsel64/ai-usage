import QuotaCore
import SwiftUI

@MainActor
struct ProviderCard: View {
    let provider: QuotaProvider
    let state: ProviderState?
    let now: Date
    let onRefresh: () -> Void
    let onShowPreferences: () -> Void

    private var hasBody: Bool {
        state?.snapshot != nil || state?.message?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ProviderCardHeader(
                provider: provider,
                state: state,
                now: now,
                onRefresh: onRefresh,
                onShowPreferences: onShowPreferences
            )
            if hasBody {
                ProviderCardBody(
                    provider: provider,
                    state: state,
                    now: now
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, hasBody ? 13 : 9)
        .background(.quaternary, in: .rect(cornerRadius: 16))
    }
}
