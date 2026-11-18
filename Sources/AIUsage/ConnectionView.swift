import AppKit
import QuotaCore
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

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
                                        value: connectionStatus(state: store.states[id])
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
        default: return "Remove Connection"
        }
    }

    private func connectButtonTitle(for provider: QuotaProvider, connected: Bool) -> String {
        if case .apiKey = provider.connection { return connected ? "Verify & Replace Key" : "Verify & Connect" }
        switch provider.connection {
        case .oauth, .browserLogin:
            return connected ? "Reconnect…" : "Connect with \(provider.displayName)"
        default:
            return connected ? "Reconnect" : "Connect"
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

    private func canConnect(_ provider: QuotaProvider) -> Bool {
        switch provider.connection {
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
        case .apiKey, .oauth, .browserLogin:
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
                executable: executable
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
