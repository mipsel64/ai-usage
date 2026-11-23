import QuotaCore
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct ResetCreditsSection: View {
    let store: UsageStore
    let provider: QuotaProvider
    let state: ProviderState?

    @ViewState private var pendingReset: PendingReset?
    @ViewState private var isUsingReset = false
    @ViewState private var result: String?
    @ViewState private var error: String?

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    content(at: context.date)
                }
            }
        } header: {
            Text("Limit resets")
        } footer: {
            if case .banked = provider.reset {
                Text("Using a reset cannot be undone. AI Usage asks you to confirm first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert(confirmationTitle, isPresented: Binding(
            get: { pendingReset != nil },
            set: { isPresented in
                if !isPresented { pendingReset = nil }
            }
        )) {
            Button("Cancel", role: .cancel) {
                pendingReset = nil
            }
            Button("Use Reset", role: .destructive) {
                guard let pendingReset else { return }
                self.pendingReset = nil
                Task { await useReset(pendingReset) }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        switch provider.reset {
        case .automaticOnly:
            Text("\(provider.displayName) resets limits automatically. It has no banked resets.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .banked:
            let options = state?.snapshot?.resetCredits?.options.filter {
                $0.expiry.map { $0 > now } ?? true
            } ?? []
            if options.isEmpty {
                Text("No limit resets are available now.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(options) { option in
                    if option.id != options.first?.id { Divider() }
                    optionRow(option, at: now)
                }
            }
        }

        if let result, !result.isEmpty {
            Text(result)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error, !error.isEmpty {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func optionRow(_ option: ResetOption, at now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = option.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(summary(for: option))
                    .foregroundStyle(.secondary)
                useButton(for: option, at: now)
            }
        }
    }

    @ViewBuilder
    private func useButton(for option: ResetOption, at now: Date) -> some View {
        let usable = store.usableResets(provider.id, at: now).contains { $0.id == option.id }
        let button = Button("Use Reset…") {
            presentConfirmation(for: option)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!usable || isUsingReset)
        .accessibilityLabel("Use one \(option.title)")

        if staleSnapshot(at: now) {
            button.help("Refresh the quota first.")
        } else {
            button
        }
    }

    private func summary(for option: ResetOption) -> String {
        let count = "\(option.count) left"
        guard let expiry = option.expiry else { return count }
        return "\(count) · expires \(expiry.formatted(date: .abbreviated, time: .omitted))"
    }

    private func staleSnapshot(at now: Date) -> Bool {
        guard let observedAt = state?.snapshot?.observedAt else { return false }
        return !(0..<(provider.refreshInterval + 90)).contains(now.timeIntervalSince(observedAt))
    }

    private func presentConfirmation(for option: ResetOption) {
        guard !isUsingReset, store.usableResets(provider.id, at: .now).contains(where: { $0.id == option.id }) else { return }
        result = nil
        error = nil
        pendingReset = PendingReset(provider: provider, option: option)
    }

    private var confirmationTitle: String {
        guard let pendingReset else { return "" }
        return "Use one \(pendingReset.option.title)?"
    }

    private var confirmationMessage: String {
        guard let pendingReset else { return "" }
        var lines: [String] = []
        if let detail = pendingReset.option.detail, !detail.isEmpty {
            lines.append(detail)
        }
        if let expiry = pendingReset.option.expiry {
            lines.append("Expires \(expiry.formatted(date: .abbreviated, time: .shortened)).")
        }
        lines.append("")
        lines.append("This uses one free reset of your \(provider.displayName) account. It cannot be undone.")
        return lines.joined(separator: "\n")
    }

    private func useReset(_ pending: PendingReset) async {
        guard !isUsingReset else { return }
        isUsingReset = true
        result = nil
        error = nil
        defer { isUsingReset = false }

        do {
            result = try await store.redeemReset(pending.provider.id, creditID: pending.option.id)
        } catch {
            self.error = connectionMessage(for: error)
        }
    }
}
