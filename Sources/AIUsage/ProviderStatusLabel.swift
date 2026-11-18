import SwiftUI

struct ProviderStatusLabel: View {
    private let staleInterval: TimeInterval = 5 * 60
    let state: ProviderState?
    let now: Date

    @ViewBuilder
    var body: some View {
        if state?.connected != true {
            Label("Not connected", systemImage: "circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if state?.needsAuthentication == true {
            Label("Sign-in required", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let snapshot = state?.snapshot,
                  now.timeIntervalSince(snapshot.observedAt) >= staleInterval {
            Label("Stale · \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if state?.snapshot == nil {
            Label(state?.loading == true ? "Reading quota…" : "Waiting for quota", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
