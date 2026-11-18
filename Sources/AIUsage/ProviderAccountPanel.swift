import AppKit
import QuotaCore
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct ProviderAccountPanel: View {
    let provider: QuotaProvider
    let state: ProviderState?

    @ViewState private var openFailureMessage: String?
    @ViewState private var copiedAddress = false

    private var accountHost: String {
        provider.accountURL.host() ?? provider.accountURL.absoluteString
    }

    private var badge: ConnectionBadge {
        if state?.needsAuthentication == true {
            return ConnectionBadge(title: "Sign-in required", status: .attention)
        }
        guard state?.connected == true else {
            return ConnectionBadge(title: "Not connected", status: .disconnected)
        }
        return ConnectionBadge(title: "Connected", status: .connected)
    }

    private var authenticationName: String {
        switch provider.connection {
        case .oauth: "OAuth"
        case .browserLogin: "Browser sign-in"
        case .apiKey: "Subscription API key"
        case .signedExecutable: "Codex CLI sign-in"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ProviderAvatar(provider: provider, size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text(provider.displayName)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    badge
                }
                Spacer()
                Button(action: openAccountPage) {
                    Label("Usage portal", systemImage: "arrow.up.right")
                }
                .usageActionStyle()
                .accessibilityHint("Opens \(accountHost) in your default browser.")
            }

            Text("Connect a \(provider.displayName) subscription to monitor quota windows and reset times.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                AccountField(title: "Access", value: "Subscription")
                AccountField(title: "Authentication", value: authenticationName)
                AccountField(title: "Account website", value: accountHost)
            }

            if let openFailureMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label(openFailureMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Try Again", action: openAccountPage)
                        Button(copiedAddress ? "Copied" : "Copy Address", action: copyAddress)
                    }
                    .controlSize(.small)
                    .usageGlassGroup()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
