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

    private let staleInterval: TimeInterval = 5 * 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                Text("AI Usage")
                    .font(.headline)
                    .padding(.bottom, 10)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.providers) { provider in
                            providerSection(for: provider, now: context.date)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 500)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset pages open in your browser. Refresh after making a change to confirm the result.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Connections…", action: showConnections)
                        Spacer()
                        Button("Quit AI Usage") {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 10)
            }
            .padding(12)
            .frame(width: 400)
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
    private func providerSection(for provider: QuotaProvider, now: Date) -> some View {
        let state = store.states[provider.id]

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.headline)

                Text(state?.connected == true ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await store.refresh(provider.id) }
                } label: {
                    if state?.loading == true {
                        ProgressView()
                            .controlSize(.small)
                            .frame(minWidth: 24, minHeight: 24)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .frame(minWidth: 24, minHeight: 24)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(state?.connected != true || state?.loading == true)
                .accessibilityLabel("Refresh \(provider.displayName)")
                .help("Refresh \(provider.displayName) quota")
            }

            if let message = state?.message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot = state?.snapshot {
                if snapshot.windows.isEmpty {
                    Text("No quota windows were reported. Refresh to try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.windows, id: \.id) { window in
                        QuotaWindowRow(window: window, now: now)
                    }
                }

                let isStale = now.timeIntervalSince(snapshot.observedAt) >= staleInterval
                Text("Last observed \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))\(isStale ? " · stale" : "")")
                    .font(.caption2)
                    .foregroundStyle(isStale ? .orange : .secondary)
                    .help(isStale ? "This data is more than five minutes old. Refresh to update it." : "When this quota data was last observed.")
            } else if state?.loading == true {
                Label("Refreshing quota…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state?.connected == true {
                Text("No quota data yet. Refresh to try again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not connected. Open Connections to set up this provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if provider.supportsBankedReset, state?.connected == true {
                if let credits = state?.snapshot?.resetCredits {
                    Text("Banked resets available: \(credits.availableCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Banked reset count not reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let result = resetResults[provider.id], !result.isEmpty {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = resetErrors[provider.id], !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                if provider.supportsBankedReset, state?.connected == true {
                    let canRedeem = store.redeemableCredit(provider.id, at: now) != nil && redeemingProvider == nil

                    Button("Redeem banked reset…") {
                        presentResetConfirmation(for: provider)
                    }
                    .disabled(!canRedeem)
                    .help(canRedeem ? "Review and redeem a banked reset." : "Refresh quota to check for an eligible banked reset.")

                    if redeemingProvider == provider.id {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let resetURL = provider.resetURL {
                    Link(provider.supportsBankedReset ? "Open usage portal" : "Open reset page", destination: resetURL)
                } else {
                    Button("Manual reset unavailable") {}
                        .disabled(true)
                }

                Spacer()

                Link(provider.supportsBankedReset ? "Inspect account" : "Account", destination: provider.accountURL)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func showConnections() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
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

private struct QuotaWindowRow: View {
    let window: QuotaWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.title)
                    .font(.subheadline)
                    .lineLimit(2)
                Spacer()
                Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))% remaining")
                    .font(.subheadline)
                    .monospacedDigit()
            }

            ProgressView(value: window.remainingPercent, total: 100)
                .accessibilityLabel("\(window.title) remaining quota")

            if let resetAt = window.resetAt {
                if hasUsableResetInterval(resetAt.timeIntervalSince(now)) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(resetCountdown(from: now, to: resetAt))
                            .monospacedDigit()
                        Spacer()
                        Text(resetAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else {
                    Text("Reset time not available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Reset time not reported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func hasUsableResetInterval(_ interval: TimeInterval) -> Bool {
        interval.isFinite && interval > -Double(Int.max) && interval < Double(Int.max)
    }

    private func resetCountdown(from now: Date, to resetAt: Date) -> String {
        let interval = resetAt.timeIntervalSince(now)
        guard hasUsableResetInterval(interval) else { return "Reset time not available" }
        guard interval > 0 else { return "Reset due — refresh" }

        var seconds = Int(ceil(interval))
        let days = seconds / 86_400
        seconds %= 86_400
        let hours = seconds / 3_600
        seconds %= 3_600
        let minutes = seconds / 60
        seconds %= 60

        if days > 0 {
            return "Resets in \(days)d \(hours)h \(minutes)m \(seconds)s"
        }
        if hours > 0 {
            return "Resets in \(hours)h \(minutes)m \(seconds)s"
        }
        if minutes > 0 {
            return "Resets in \(minutes)m \(seconds)s"
        }
        return "Resets in \(seconds)s"
    }
}

@MainActor
struct ConnectionView: View {
    let store: UsageStore

    @ViewState private var secrets: [ProviderID: String] = [:]
    @ViewState private var executables: [ProviderID: URL] = [:]
    @ViewState private var errors: [ProviderID: String] = [:]
    @ViewState private var busyProviders: Set<ProviderID> = []
    @ViewState private var copiedStatusLineCommand = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connections")
                        .font(.largeTitle)
                        .bold()
                    Text("Connect only the providers you use. Credential fields start empty and are cleared after each connection attempt.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                notificationsSection

                ForEach(store.providers) { provider in
                    connectionSection(for: provider)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var notificationsSection: some View {
        GroupBox("Notifications") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "Notify me when a quota resets",
                    isOn: Binding(
                        get: { store.notificationsEnabled },
                        set: { enabled in
                            Task { await store.setNotifications(enabled) }
                        }
                    )
                )

                Text("Notifications are off unless you turn them on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !store.notificationStatus.isEmpty {
                    Text(store.notificationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func connectionSection(for provider: QuotaProvider) -> some View {
        let state = store.states[provider.id]
        let isBusy = busyProviders.contains(provider.id) || state?.loading == true

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                switch provider.connection {
                case let .statusLine(toolName, helperName):
                    statusLineSetup(toolName: toolName, helperName: helperName)
                case .signedExecutable:
                    signedExecutableSetup(for: provider)
                case .apiKey:
                    secretSetup(for: provider)
                }

                if let message = errors[provider.id] ?? state?.message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button(state?.connected == true ? "Reconnect" : "Connect") {
                        Task { await connect(provider) }
                    }
                    .disabled(isBusy || !canConnect(provider))

                    if state?.connected == true {
                        Button("Remove Connection", role: .destructive) {
                            Task { await disconnect(provider) }
                        }
                        .disabled(isBusy)
                    }

                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Link("Provider account", destination: provider.accountURL)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.headline)
                Text(state?.connected == true ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusLineSetup(toolName: String, helperName: String) -> some View {
        let command = statusLineCommand(helperName: helperName)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Merge this standalone helper into statusLine.command in your \(toolName) settings, then connect below.")
                .fixedSize(horizontal: false, vertical: true)

            Text("To keep an existing status line, append --passthrough | <your existing command>. Your existing command receives \(toolName)'s original JSON payload.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button(copiedStatusLineCommand ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedStatusLineCommand = true
                }
                Text("The app does not change your \(toolName) settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func signedExecutableSetup(for provider: QuotaProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Choose the signed native \(provider.displayName) executable, not an npm wrapper. Select only the official executable that you trust.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Choose \(provider.displayName) Executable…") {
                    chooseExecutable(for: provider)
                }
                if let executable = executables[provider.id] {
                    Text(executable.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let executable = executables[provider.id] {
                Text(executable.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func secretSetup(for provider: QuotaProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter a new \(provider.displayName) API key to connect or reconnect. It is never prefilled.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField(
                "\(provider.displayName) API key",
                text: Binding(
                    get: { secrets[provider.id] ?? "" },
                    set: { secrets[provider.id] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
        }
    }

    private func statusLineCommand(helperName: String) -> String {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers")
            .appendingPathComponent(helperName)
        return shellQuoted(helper.path)
    }

    private func canConnect(_ provider: QuotaProvider) -> Bool {
        switch provider.connection {
        case .statusLine:
            return true
        case .signedExecutable:
            return executables[provider.id] != nil
        case .apiKey:
            return !(secrets[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    private func chooseExecutable(for provider: QuotaProvider) {
        let panel = NSOpenPanel()
        panel.title = "Choose the Official \(provider.displayName) Executable"
        panel.message = "Choose the signed native executable, not an npm wrapper."
        panel.prompt = "Choose Executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        executables[provider.id] = panel.url
        errors[provider.id] = nil
    }

    private func connect(_ provider: QuotaProvider) async {
        let id = provider.id
        guard !busyProviders.contains(id), canConnect(provider) else { return }

        let secret = secrets[id]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable: URL?
        switch provider.connection {
        case .signedExecutable:
            executable = executables[id]
        case .statusLine, .apiKey:
            executable = nil
        }

        busyProviders.insert(id)
        errors[id] = nil
        defer {
            busyProviders.remove(id)
            if case .apiKey = provider.connection {
                secrets[id] = ""
            }
        }

        do {
            try await store.connect(id, secret: secret, executable: executable)
        } catch {
            errors[id] = connectionMessage(for: error)
        }
    }

    private func disconnect(_ provider: QuotaProvider) async {
        let id = provider.id
        guard !busyProviders.contains(id) else { return }

        busyProviders.insert(id)
        errors[id] = nil
        defer { busyProviders.remove(id) }

        do {
            try await store.disconnect(id)
            secrets[id] = nil
            if case .signedExecutable = provider.connection {
                executables[id] = nil
            }
        } catch {
            errors[id] = connectionMessage(for: error)
        }
    }
}

private func connectionMessage(for error: Error) -> String {
    guard let quotaError = error as? QuotaError else {
        return error.localizedDescription
    }

    switch quotaError {
    case .notConfigured:
        return "Setup is incomplete. Check the connection details and try again."
    case .invalidResponse:
        return "The provider returned an unreadable response. Try again."
    case .unauthorized:
        return "The credentials were not accepted. Reconnect with valid credentials."
    case .rateLimited:
        return "The provider is rate limiting requests. Try again later."
    case .unavailable:
        return "The provider is unavailable. Try again later."
    }
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
