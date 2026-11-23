import QuotaCore
import SwiftUI

struct ProviderCardBody: View {
    let provider: QuotaProvider
    let state: ProviderState?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = state?.message, !message.isEmpty {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot = state?.snapshot {
                let windows = snapshot.windows.filter { provider.id != .kimi || $0.id != "kimi-monthly-code" }
                if windows.isEmpty {
                    Text("No quota windows reported. Refresh to try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 9) {
                        ForEach(windows) { window in
                            QuotaWindowRow(window: window, now: now)
                        }
                    }
                }
            }
        }
    }
}
