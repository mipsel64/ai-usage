import QuotaCore
import SwiftUI

@MainActor
struct QuotaMenuHeader: View {
    let store: UsageStore

    private var latestObservation: Date? {
        store.states.values
            .filter { $0.connected }
            .compactMap(\.snapshot?.observedAt)
            .max()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("AI Usage")
                .font(.headline)
            Spacer(minLength: 8)
            if let latestObservation {
                Text("Updated \(latestObservation.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Refresh All", systemImage: "arrow.clockwise", action: refreshAll)
                .labelStyle(.iconOnly)
                .usageActionStyle()
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .accessibilityLabel("Refresh All")
                .help("Refresh all connected providers")
        }
    }

    private func refreshAll() {
        for provider in store.providers {
            guard let state = store.states[provider.id], state.connected, !state.needsAuthentication else { continue }
            Task { await store.refresh(provider.id, interactive: true) }
        }
    }
}
