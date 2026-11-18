import QuotaCore
import SwiftUI

@MainActor
struct ProviderCard: View {
    let provider: QuotaProvider
    let state: ProviderState?
    let now: Date
    let isConnecting: Bool
    let canRedeem: Bool
    let resetResult: String?
    let resetError: String?
    let connectionError: String?
    let onConnect: () -> Void
    let onRefresh: () -> Void
    let onShowAccounts: () -> Void
    let onRedeem: () -> Void

    private var hasBody: Bool {
        guard state?.connected == true || connectionError?.isEmpty == false else { return false }
        return state?.snapshot != nil || state?.message?.isEmpty == false ||
            resetResult?.isEmpty == false || resetError?.isEmpty == false || connectionError?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ProviderCardHeader(
                provider: provider,
                state: state,
                now: now,
                isConnecting: isConnecting,
                canRedeem: canRedeem,
                onConnect: onConnect,
                onRefresh: onRefresh,
                onShowAccounts: onShowAccounts,
                onRedeem: onRedeem
            )
            if hasBody {
                ProviderCardBody(
                    provider: provider,
                    state: state,
                    now: now,
                    resetResult: resetResult,
                    resetError: resetError,
                    connectionError: connectionError
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, hasBody ? 13 : 9)
        .background(.quaternary, in: .rect(cornerRadius: 16))
    }
}
