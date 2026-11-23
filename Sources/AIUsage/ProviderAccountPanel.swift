import AppKit
import QuotaCore
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct ProviderAccountPanel: View {
    let store: UsageStore
    let provider: QuotaProvider
    let state: ProviderState?

    @Binding var secret: String
    @Binding var executable: URL?
    @Binding var error: String?
    @Binding var isBusy: Bool

    @ViewState private var openFailureMessage: String?
    @ViewState private var copiedAddress = false

    private var accountHost: String {
        provider.accountURL.host() ?? provider.accountURL.absoluteString
    }

    private var authenticationName: String {
        switch provider.connection {
        case .oauth: "OAuth"
        case .browserLogin: "Browser sign-in"
        case .apiKey: "Subscription API key"
        case .signedExecutable: "Codex CLI sign-in"
        }
    }

    private var storesCredential: Bool {
        switch provider.connection {
        case .apiKey, .browserLogin, .oauth: true
        case .signedExecutable: false
        }
    }

    private var isWorking: Bool {
        isBusy || state?.loading == true
    }

    var body: some View {
        VStack(spacing: 0) {
            PreferencesPaneHeader(
                title: provider.displayName,
                subtitle: "Quota windows and reset times of this subscription."
            ) {
                ProviderAvatar(provider: provider, size: 36)
            } accessory: {
                Button("Usage Portal", systemImage: "arrow.up.right", action: openAccountPage)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .labelStyle(.titleAndIcon)
                    .accessibilityHint("Opens \(accountHost) in your default browser.")
                    .help("Opens \(accountHost) in your default browser.")
            }

            form
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var form: some View {
        Form {
            if state?.connected == true {
                AccountIdentitySection(account: state?.account)
            }

            ProviderConnectionSection(
                provider: provider,
                state: state,
                authenticationName: authenticationName,
                storesCredential: storesCredential,
                message: error ?? state?.message,
                messageIsError: error != nil || state?.needsAuthentication == true,
                secret: $secret,
                executable: $executable,
                chooseExecutable: chooseExecutable,
                actions: ProviderConnectionActions(
                    disconnectTitle: state?.connected == true ? disconnectButtonTitle : nil,
                    connectTitle: connectButtonTitle,
                    isBusy: isWorking,
                    canConnect: canConnect,
                    connectIsProminent: state?.connected != true || state?.needsAuthentication == true,
                    connect: startConnecting,
                    disconnect: startDisconnecting
                )
            )

            if provider.id == .claude {
                ClaudeCodeVersionSection()
            }

            if let openFailureMessage {
                AccountPortalFailure(
                    message: openFailureMessage,
                    copiedAddress: copiedAddress,
                    tryAgain: openAccountPage,
                    copyAddress: copyAddress
                )
            }
        }
        .formStyle(.grouped)
    }

    private var disconnectButtonTitle: String {
        switch provider.connection {
        case .oauth, .browserLogin: "Disconnect"
        default: "Remove Connection"
        }
    }

    private var connectButtonTitle: String {
        let connected = state?.connected == true
        if case .apiKey = provider.connection {
            return connected ? "Verify & Replace Key" : "Verify & Connect"
        }
        switch provider.connection {
        case .oauth, .browserLogin:
            if !connected { return "Connect with \(provider.displayName)" }
            return state?.needsAuthentication == true ? "Sign In…" : "Reconnect…"
        default:
            return connected ? "Reconnect" : "Connect"
        }
    }

    private var canConnect: Bool {
        switch provider.connection {
        case .signedExecutable:
            executable != nil
        case .apiKey:
            !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .oauth, .browserLogin:
            true
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Official \(provider.displayName) Executable"
        panel.message = "Choose the signed native executable, not an npm wrapper."
        panel.prompt = "Choose Executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        executable = panel.url
        error = nil
    }

    private func startConnecting() {
        Task { await connect() }
    }

    private func connect() async {
        guard !isBusy, canConnect else { return }
        let enteredSecret: String?
        let selectedExecutable: URL?
        switch provider.connection {
        case .signedExecutable:
            enteredSecret = nil
            selectedExecutable = executable
        case .apiKey:
            enteredSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedExecutable = nil
        case .oauth, .browserLogin:
            enteredSecret = nil
            selectedExecutable = nil
        }

        isBusy = true
        error = nil
        defer {
            isBusy = false
            if case .apiKey = provider.connection {
                secret = ""
            }
        }

        do {
            try await store.connect(provider.id, secret: enteredSecret, executable: selectedExecutable)
        } catch {
            self.error = connectionMessage(for: error)
        }
    }

    private func startDisconnecting() {
        Task { await disconnect() }
    }

    private func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }

        do {
            try await store.disconnect(provider.id)
            secret = ""
            if case .signedExecutable = provider.connection {
                executable = nil
            }
        } catch {
            self.error = connectionMessage(for: error)
        }
    }

    private func openAccountPage() {
        let url = provider.accountURL
        guard url.scheme?.localizedLowercase == "https", url.host() != nil else {
            openFailureMessage = "AI Usage has no valid https address for \(provider.displayName). Update the app; you can still copy the saved address to inspect it."
            return
        }

        openFailureMessage = nil
        if !NSWorkspace.shared.open(url) {
            openFailureMessage = "macOS could not open \(accountHost). Set a default web browser in System Settings and try again, or copy the address and open it in any browser."
        }
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(provider.accountURL.absoluteString, forType: .string)
        copiedAddress = true
    }
}
