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

    private let staleInterval: TimeInterval = 5 * 60

    private var connectedCount: Int {
        store.states.values.count(where: { $0.connected && !$0.needsAuthentication })
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 0) {
                Button(action: { showAccounts() }) {
                    HStack(spacing: 12) {
                        AIUsageAppIcon()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("AI Usage")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                            Label {
                                Text("\(connectedCount) of \(store.providers.count) subscriptions connected")
                                    .foregroundStyle(.secondary)
                            } icon: {
                                Circle()
                                    .fill(connectedCount == 0 ? Color.secondary : Color.green)
                                    .frame(width: 7, height: 7)
                            }
                            .font(.caption)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("AI Usage accounts")
                .accessibilityHint("Opens account and notification settings.")

                Divider()

                providerList(now: context.date)

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    MenuActionRow(
                        title: "Manage Accounts…",
                        systemImage: "person.crop.circle",
                        shortcut: "⌘,",
                        action: { showAccounts() }
                    )
                    .keyboardShortcut(",", modifiers: .command)
                    MenuActionRow(
                        title: "Quit AI Usage",
                        systemImage: "power",
                        shortcut: "⌘Q"
                    ) {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q", modifiers: .command)
                }
                .padding(8)
            }
            .frame(width: 400)
            .background(MenuPopoverBackdrop())
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
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

    @ViewBuilder
    private func providerList(now: Date) -> some View {
        VStack(spacing: 0) {
            ForEach(store.providers) { provider in
                providerSection(for: provider, now: now)
                if provider.id != store.providers.last?.id {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func providerSection(for provider: QuotaProvider, now: Date) -> some View {
        let state = store.states[provider.id]
        let isMonitoring = state?.connected == true

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(provider.displayName)
                    .font(.headline)
                if isMonitoring {
                    Image(systemName: state?.needsAuthentication == true ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(state?.needsAuthentication == true ? .orange : .green)
                        .accessibilityLabel(state?.needsAuthentication == true ? "Sign-in required" : "Connected")
                }
                Spacer()
                if isMonitoring && state?.needsAuthentication != true {
                    Button {
                        Task { await store.refresh(provider.id, interactive: true) }
                    } label: {
                        if state?.loading == true {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 24, height: 22)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .frame(width: 24, height: 22)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(state?.loading == true)
                    .accessibilityLabel("Refresh \(provider.displayName)")
                    .help("Refresh \(provider.displayName) quota")
                } else {
                    Button {
                        connectFromMenu(provider)
                    } label: {
                        if connectingProviders.contains(provider.id) {
                            ProgressView()
                                .controlSize(.small)
                                .frame(minWidth: 52)
                        } else {
                            Text(isMonitoring ? "Sign In" : "Connect")
                        }
                    }
                    .usageActionStyle(prominent: true)
                    .controlSize(.small)
                    .disabled(connectingProviders.contains(provider.id))
                    .accessibilityLabel(isMonitoring ? "Sign in to \(provider.displayName)" : "Connect \(provider.displayName)")
                }
            }

            if isMonitoring {
                if let message = state?.message, !message.isEmpty {
                    Label(message, systemImage: state?.needsAuthentication == true ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption2)
                        .foregroundStyle(state?.needsAuthentication == true ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let snapshot = state?.snapshot {
                    let windows = snapshot.windows.filter { provider.id != .kimi || $0.id != "kimi-monthly-code" }
                    if windows.isEmpty {
                        Text("No quota windows reported. Refresh to try again.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 7) {
                            ForEach(windows, id: \.id) { window in
                                QuotaWindowRow(window: window, now: now)
                            }
                        }
                    }
                }

                if provider.supportsBankedReset {
                    HStack(spacing: 8) {
                        if let credits = state?.snapshot?.resetCredits {
                            Text("\(credits.availableCount) banked reset\(credits.availableCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let canRedeem = store.redeemableCredit(provider.id, at: now) != nil && redeemingProvider == nil
                        Button {
                            presentResetConfirmation(for: provider)
                        } label: {
                            if redeemingProvider == provider.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Redeem reset…")
                            }
                        }
                        .usageActionStyle()
                        .controlSize(.small)
                        .disabled(!canRedeem)
                        .help("Review and redeem one eligible banked reset.")
                    }
                }

                if let result = resetResults[provider.id], !result.isEmpty {
                    Text(result)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = resetErrors[provider.id], !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = connectionErrors[provider.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if let snapshot = state?.snapshot {
                    let isStale = now.timeIntervalSince(snapshot.observedAt) >= staleInterval
                    Label {
                        Text("Updated \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))\(isStale ? " · Stale" : "")")
                    } icon: {
                        Image(systemName: isStale ? "exclamationmark.circle" : "clock")
                    }
                    .foregroundStyle(isStale ? .orange : .secondary)
                } else if isMonitoring {
                    Text(state?.loading == true ? "Reading quota…" : "Waiting for quota")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Subscription not connected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                usagePortalLink(for: provider)
            }
            .font(.caption2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func usagePortalLink(for provider: QuotaProvider) -> some View {
        Link(destination: provider.resetURL ?? provider.accountURL) {
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 18)
        }
        .accessibilityLabel("Open \(provider.displayName) usage portal")
        .accessibilityHint("Opens the official \(provider.displayName) website in your browser.")
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

private struct PendingReset {
    let provider: QuotaProvider
    let creditID: String
    let title: String?
    let expiry: Date?
}
