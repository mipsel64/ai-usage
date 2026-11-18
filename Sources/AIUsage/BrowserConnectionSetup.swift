import QuotaCore
import SwiftUI

struct BrowserConnectionSetup: View {
    let provider: QuotaProvider
    let state: ProviderState?

    private var connected: Bool { state?.connected == true }
    private var needsAuthentication: Bool { state?.needsAuthentication == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(connected ? "\(provider.displayName) subscription" : "Browser sign-in")
            Text(
                needsAuthentication
                    ? "Reconnect to renew your authorization."
                    : connected ? "Your subscription connection is active." : "Use your provider account to connect AI Usage."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
