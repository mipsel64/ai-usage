import AppKit
import QuotaCore
import SwiftUI

@MainActor
struct QuotaMenu: View {
    let store: UsageStore

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 0) {
                QuotaMenuHeader(store: store)
                    .padding(.leading, 12)
                    .padding(.trailing, 11)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                let activeProviders = store.activeProviders
                if activeProviders.isEmpty {
                    Text("No active subscription. Open Preferences to connect or sign in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach(activeProviders) { provider in
                            ProviderCard(
                                provider: provider,
                                state: store.states[provider.id],
                                now: context.date,
                                onRefresh: { refresh(provider) },
                                onShowPreferences: { showPreferences(provider) }
                            )
                        }
                    }
                }

                Divider()
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                    .padding(.bottom, 5)

                VStack(alignment: .leading, spacing: 0) {
                    MenuActionRow(
                        title: "Preferences…",
                        systemImage: "gearshape",
                        shortcut: "⌘,",
                        showsSignInDot: store.needsSignIn,
                        action: { showPreferences() }
                    )
                    .keyboardShortcut(",", modifiers: .command)
                    MenuActionRow(
                        title: "Quit AI Usage",
                        systemImage: "power",
                        shortcut: "⌘Q",
                        action: quit
                    )
                    .keyboardShortcut("q", modifiers: .command)
                }
            }
            .padding(6)
            .frame(width: 340)
            .background(MenuPopoverBackdrop())
        }
    }

    private func refresh(_ provider: QuotaProvider) {
        Task { await store.refresh(provider.id, interactive: true) }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showPreferences(_ provider: QuotaProvider? = nil) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
        guard let provider else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showProviderAccount, object: provider.id)
        }
    }
}
