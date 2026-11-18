import QuotaCore
import SwiftUI

@MainActor
struct QuotaMenuHeader: View {
    let store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let refreshButtonSize: CGFloat = 26

    private var latestObservation: Date? {
        store.states.values
            .filter { $0.connected }
            .compactMap(\.snapshot?.observedAt)
            .max()
    }

    private var refreshableProviders: [QuotaProvider] {
        store.providers.filter { provider in
            guard let state = store.states[provider.id] else { return false }
            return state.connected && !state.needsAuthentication && !state.loading
        }
    }

    private var isRefreshing: Bool {
        store.states.values.contains { $0.connected && $0.loading }
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
            Button(action: refreshAll) {
                Label {
                    Text("Refresh All")
                } icon: {
                    refreshIcon
                }
            }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .frame(width: Self.refreshButtonSize, height: Self.refreshButtonSize)
                .contentShape(.rect)
                .disabled(refreshableProviders.isEmpty && !isRefreshing)
                .accessibilityLabel("Refresh All")
                .help("Refresh all connected providers")
        }
    }

    @ViewBuilder
    private var refreshIcon: some View {
        let icon = Image(systemName: "arrow.clockwise")
        if #available(macOS 15.0, *) {
            icon.symbolEffect(.rotate, options: .repeat(.continuous), isActive: isRefreshing && !reduceMotion)
        } else {
            icon
        }
    }

    private func refreshAll() {
        for provider in refreshableProviders {
            Task { await store.refresh(provider.id, interactive: true) }
        }
    }
}
