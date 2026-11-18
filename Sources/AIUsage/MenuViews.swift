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

private func supportsDesktopFeed(_ provider: QuotaProvider) -> Bool {
    guard case let .statusLine(_, _, desktopPlugin) = provider.connection else { return false }
    return desktopPlugin
}

@MainActor
private func connectionStatus(for provider: QuotaProvider, state: ProviderState?, store: UsageStore) -> String {
    if state?.needsAuthentication == true { return "Access denied" }
    guard supportsDesktopFeed(provider) else {
        guard state?.connected == true else { return "Monitoring off" }
        return state?.snapshot == nil ? "Waiting for quota" : "Monitoring on"
    }
    guard state?.connected == true else { return "Monitoring off" }
    let source = store.usesDesktopFeed(provider.id) ? "Desktop feed" : "Status-line feed"
    return state?.snapshot == nil ? "\(source) · waiting for quota" : "\(source) · monitoring on"
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let resetAt = window.resetAt {
                    Text(resetCountdown(from: now, to: resetAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))%")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            ProgressView(value: window.remainingPercent, total: 100)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(UsageVisuals.quotaColor(remaining: window.remainingPercent))
                .accessibilityLabel("\(window.title) remaining quota")
                .accessibilityValue("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1)))) percent")
        }
    }

    private func hasUsableResetInterval(_ interval: TimeInterval) -> Bool {
        interval.isFinite && interval > -Double(Int.max) && interval < Double(Int.max)
    }

    private func resetCountdown(from now: Date, to resetAt: Date) -> String {
        let interval = resetAt.timeIntervalSince(now)
        guard hasUsableResetInterval(interval) else { return "Reset unavailable" }
        guard interval > 0 else { return "Reset due" }
        let totalMinutes = max(1, Int(ceil(interval / 60)))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "Resets in \(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }
}

private extension Notification.Name {
    static let showProviderAccount = Notification.Name("AIUsage.ShowProviderAccount")
}

private enum AccountSelection: Hashable {
    case provider(ProviderID)
    case notifications
}

@MainActor
struct ConnectionView: View {
    let store: UsageStore

    @ViewState private var selection: AccountSelection?
    @ViewState private var searchText = ""
    @ViewState private var secrets: [ProviderID: String] = [:]
    @ViewState private var executables: [ProviderID: URL] = [:]
    @ViewState private var errors: [ProviderID: String] = [:]
    @ViewState private var busyProviders: Set<ProviderID> = []
    @ViewState private var desktopFeedSelections: [ProviderID: Bool] = [:]
    @ViewState private var copiedStatusLineCommand = false

    private var visibleProviders: [QuotaProvider] {
        guard !searchText.isEmpty else { return store.providers }
        return store.providers.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedTitle: String {
        if selection == .notifications { return "Notifications" }
        if case let .provider(id) = selection,
           let provider = store.providers.first(where: { $0.id == id }) {
            return provider.displayName
        }
        return "AI Usage"
    }

    private func sidebarStatus(for provider: QuotaProvider) -> String {
        let state = store.states[provider.id]
        if state?.needsAuthentication == true { return "Sign-in required" }
        return state?.connected == true ? "Connected" : "Not connected"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(visibleProviders) { provider in
                    HStack(spacing: 10) {
                        ProviderAvatar(provider: provider, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                            Text(sidebarStatus(for: provider))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(AccountSelection.provider(provider.id))
                }
                if searchText.isEmpty || "Notifications".localizedCaseInsensitiveContains(searchText) {
                    Label("Notifications", systemImage: "bell")
                        .padding(.vertical, 5)
                        .tag(AccountSelection.notifications)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(UsagePanelColors.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search Settings")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if selection == .notifications {
                        notificationsSection
                    } else if case let .provider(id) = selection,
                              let provider = store.providers.first(where: { $0.id == id }) {
                        ProviderAccountPanel(provider: provider, state: store.states[id])
                            .id(id)

                        SettingsSection(title: "Connection", systemImage: "link") {
                            connectionSection(for: provider)
                        }

                        if store.states[id]?.connected == true {
                            SettingsSection(title: "Activity", systemImage: "chart.bar") {
                                VStack(spacing: 0) {
                                    SettingsValueRow(
                                        title: "Monitoring",
                                        value: connectionStatus(for: provider, state: store.states[id], store: store)
                                    )
                                    if let date = store.states[id]?.snapshot?.observedAt {
                                        Divider()
                                        SettingsValueRow(title: "Last quota reading", value: date.formatted(date: .numeric, time: .shortened))
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(UsagePanelColors.outer)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(UsagePanelColors.outer, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle(selectedTitle)
        .frame(minWidth: 720, idealWidth: 780, minHeight: 500, idealHeight: 560)
        .onAppear {
            if selection == nil { selection = store.providers.first.map { .provider($0.id) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showProviderAccount)) { notification in
            guard let id = notification.object as? ProviderID,
                  store.providers.contains(where: { $0.id == id }) else { return }
            selection = .provider(id)
        }
        .onChange(of: selection) {
            secrets.removeAll()
            copiedStatusLineCommand = false
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Quota reset alerts while AI Usage is running.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsSection(title: "Reset alerts", systemImage: "arrow.clockwise.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Notify me when a quota resets",
                        isOn: Binding(
                            get: { store.notificationsEnabled },
                            set: { enabled in
                                Task { await store.setNotifications(enabled) }
                            }
                        )
                    )

                    Text("AI Usage checks active subscription sources about once a minute. Quitting the app stops checks and alerts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !store.notificationStatus.isEmpty {
                        Label(store.notificationStatus, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func connectionSection(for provider: QuotaProvider) -> some View {
        let state = store.states[provider.id]
        let isBusy = busyProviders.contains(provider.id) || state?.loading == true

        VStack(alignment: .leading, spacing: 14) {
            switch provider.connection {
            case let .statusLine(toolName, helperName, desktopPlugin):
                statusLineSetup(for: provider, toolName: toolName, helperName: helperName, desktopPlugin: desktopPlugin)
            case .signedExecutable:
                signedExecutableSetup(for: provider)
            case .apiKey:
                secretSetup(for: provider)
            case .oauth, .browserLogin:
                browserConnectionSummary(for: provider, state: state)
            }

            if let message = errors[provider.id] ?? state?.message, !message.isEmpty {
                let isError = errors[provider.id] != nil || state?.needsAuthentication == true
                Label(message, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 10) {
                if case .oauth = provider.connection {
                    Label("Secured in login Keychain", systemImage: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if case .browserLogin = provider.connection {
                    Label("Secured in login Keychain", systemImage: "key.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if state?.connected == true {
                    Button(disconnectButtonTitle(for: provider), role: .destructive) {
                        Task { await disconnect(provider) }
                    }
                    .usageActionStyle()
                    .disabled(isBusy)
                }
                Button(connectButtonTitle(for: provider, connected: state?.connected == true)) {
                    Task { await connect(provider) }
                }
                .usageActionStyle(prominent: state?.connected != true || state?.needsAuthentication == true)
                .disabled(isBusy || !canConnect(provider))
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                }
            }
            .usageGlassGroup()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func browserConnectionSummary(for provider: QuotaProvider, state: ProviderState?) -> some View {
        let connected = state?.connected == true
        let needsAuthentication = state?.needsAuthentication == true
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(connected ? "\(provider.displayName) subscription" : "Browser sign-in")
                    .font(.body.weight(.medium))
                Text(
                    needsAuthentication
                        ? "Reconnect to renew your authorization."
                        : connected ? "Your subscription connection is active." : "Use your provider account to connect AI Usage."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if connected {
                ConnectionBadge(
                    title: needsAuthentication ? "Action needed" : "Connected",
                    status: needsAuthentication ? .attention : .connected
                )
            }
        }
    }

    private func disconnectButtonTitle(for provider: QuotaProvider) -> String {
        switch provider.connection {
        case .oauth, .browserLogin: return "Disconnect"
        default: return store.usesDesktopFeed(provider.id) ? "Stop Monitoring" : "Remove Connection"
        }
    }

    private func connectButtonTitle(for provider: QuotaProvider, connected: Bool) -> String {
        if usesDesktopFeedSelection(for: provider) {
            return connected ? "Restart Monitoring" : "Start Monitoring"
        }
        if case .apiKey = provider.connection { return connected ? "Verify & Replace Key" : "Verify & Connect" }
        switch provider.connection {
        case .oauth, .browserLogin:
            return connected ? "Reconnect…" : "Connect with \(provider.displayName)"
        default:
            return connected ? "Reconnect" : "Connect"
        }
    }


    @ViewBuilder
    private func statusLineSetup(
        for provider: QuotaProvider,
        toolName: String,
        helperName: String,
        desktopPlugin: Bool
    ) -> some View {
        if desktopPlugin {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Quota source", selection: desktopFeedBinding(for: provider)) {
                    Text("Claude Desktop local plugin").tag(true)
                    Text("\(toolName) status-line helper").tag(false)
                }
                .pickerStyle(.radioGroup)

                Text("The source preference is saved only when you connect or reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if usesDesktopFeedSelection(for: provider) {
                    ClaudeDesktopSetupView()
                } else {
                    statusLineInstructions(toolName: toolName, helperName: helperName)
                }
            }
        } else {
            statusLineInstructions(toolName: toolName, helperName: helperName)
        }
    }

    private func statusLineInstructions(toolName: String, helperName: String) -> some View {
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

    private func desktopFeedBinding(for provider: QuotaProvider) -> Binding<Bool> {
        Binding(
            get: { usesDesktopFeedSelection(for: provider) },
            set: { selected in
                desktopFeedSelections[provider.id] = selected
                errors[provider.id] = nil
            }
        )
    }

    private func usesDesktopFeedSelection(for provider: QuotaProvider) -> Bool {
        guard supportsDesktopFeed(provider) else { return false }
        return desktopFeedSelections[provider.id] ?? (store.states[provider.id]?.connected != true || store.usesDesktopFeed(provider.id))
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
        case .oauth, .browserLogin:
            return true
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
        case .statusLine, .apiKey, .oauth, .browserLogin:
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
            try await store.connect(
                id,
                secret: secret,
                executable: executable,
                desktopFeed: usesDesktopFeedSelection(for: provider)
            )
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
