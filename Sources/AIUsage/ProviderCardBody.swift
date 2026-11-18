import QuotaCore
import SwiftUI

struct ProviderCardBody: View {
    private let staleInterval: TimeInterval = 5 * 60
    let provider: QuotaProvider
    let state: ProviderState?
    let now: Date
    let resetResult: String?
    let resetError: String?
    let connectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = state?.message, !message.isEmpty {
                Label(message, systemImage: state?.needsAuthentication == true ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(state?.needsAuthentication == true ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state?.needsAuthentication == true, let snapshot = state?.snapshot,
               now.timeIntervalSince(snapshot.observedAt) >= staleInterval {
                Label("Last reading \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.orange)
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

            if let resetResult, !resetResult.isEmpty {
                Text(resetResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resetError, !resetError.isEmpty {
                Label(resetError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let connectionError, !connectionError.isEmpty {
                Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
