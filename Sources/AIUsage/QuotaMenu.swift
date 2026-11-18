import AppKit
import QuotaCore
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct QuotaMenu: View {
    let store: UsageStore

    @Environment(\.openSettings) private var openSettings
    @ViewState private var pendingReset: PendingReset?
    @ViewState private var redeemingProvider: ProviderID?
    @ViewState private var resetResults: [ProviderID: String] = [:]
    @ViewState private var resetErrors: [ProviderID: String] = [:]
    @ViewState private var connectionErrors: [ProviderID: String] = [:]
    @ViewState private var connectingProviders: Set<ProviderID> = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 0) {
                QuotaMenuHeader(store: store)
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .padding(.top, 6)
                    .padding(.bottom, 8)

                VStack(spacing: 6) {
                    ForEach(store.providers) { provider in
                        ProviderCard(
                            provider: provider,
                            state: store.states[provider.id],
                            now: context.date,
                            isConnecting: connectingProviders.contains(provider.id),
                            canRedeem: canRedeem(provider, at: context.date),
                            resetResult: resetResults[provider.id],
                            resetError: resetErrors[provider.id],
                            connectionError: connectionErrors[provider.id],
                            onConnect: { connectFromMenu(provider) },
                            onRefresh: { refresh(provider) },
                            onShowAccounts: { showAccounts(provider) },
                            onRedeem: { presentResetConfirmation(for: provider) }
                        )
                    }
                }

                Divider()
                    .padding(.horizontal, 10)
                    .padding(.top, 7)
                    .padding(.bottom, 5)

                VStack(alignment: .leading, spacing: 0) {
                    MenuActionRow(
                        title: "Accounts…",
                        systemImage: "person.crop.circle",
                        shortcut: "⌘,",
                        action: showAllAccounts
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
        .alert(
            "Redeem one banked reset?",
            isPresented: Binding(
                get: { pendingReset != nil },
                set: { isPresented in
                    if !isPresented { pendingReset = nil }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingReset = nil
            }
            Button("Redeem One Reset", role: .destructive) {
                guard let pendingReset else { return }
                self.pendingReset = nil
                Task { await redeemReset(pendingReset) }
            }
        } message: {
            Text(resetConfirmationMessage)
        }
    }

    private func canRedeem(_ provider: QuotaProvider, at now: Date) -> Bool {
        store.redeemableCredit(provider.id, at: now) != nil && redeemingProvider == nil
    }

    private func refresh(_ provider: QuotaProvider) {
        Task { await store.refresh(provider.id, interactive: true) }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showAllAccounts() {
        showAccounts()
    }

    private func connectFromMenu(_ provider: QuotaProvider) {
        switch provider.connection {
        case .oauth, .browserLogin:
            break
        default:
            showAccounts(provider)
            return
        }
        guard !connectingProviders.contains(provider.id) else { return }

        connectingProviders.insert(provider.id)
        connectionErrors[provider.id] = nil
        Task {
            defer { connectingProviders.remove(provider.id) }
            do {
                try await store.connect(provider.id)
            } catch {
                connectionErrors[provider.id] = connectionMessage(for: error)
            }
        }
    }

    private func showAccounts(_ provider: QuotaProvider? = nil) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
        guard let provider else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showProviderAccount, object: provider.id)
        }
    }

    private func presentResetConfirmation(for provider: QuotaProvider) {
        guard let credits = store.redeemableCredit(provider.id, at: .now),
              let creditID = credits.nextID, redeemingProvider == nil else { return }

        resetErrors[provider.id] = nil
        pendingReset = PendingReset(
            provider: provider,
            creditID: creditID,
            title: credits.nextTitle,
            expiry: credits.nextExpiry
        )
    }

    private var resetConfirmationMessage: String {
        guard let pendingReset else { return "" }

        var details: [String] = []
        if let title = pendingReset.title, !title.isEmpty {
            details.append(title)
        }
        if let expiry = pendingReset.expiry {
            details.append("Expires \(expiry.formatted(date: .abbreviated, time: .shortened)).")
        }

        let creditDetails = details.isEmpty ? "" : details.joined(separator: "\n") + "\n\n"
        return "\(creditDetails)This consumes one nonrefundable free entitlement for the signed-in \(pendingReset.provider.displayName) CLI account. It does not make a purchase. Cancel and inspect the \(pendingReset.provider.displayName) account first if you are unsure."
    }

    private func redeemReset(_ pending: PendingReset) async {
        guard redeemingProvider == nil else { return }

        redeemingProvider = pending.provider.id
        resetErrors[pending.provider.id] = nil
        resetResults[pending.provider.id] = nil
        defer { redeemingProvider = nil }

        do {
            resetResults[pending.provider.id] = try await store.redeemReset(
                pending.provider.id,
                creditID: pending.creditID
            )
        } catch {
            resetErrors[pending.provider.id] = connectionMessage(for: error)
        }
    }
}
