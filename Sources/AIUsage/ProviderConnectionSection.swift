import QuotaCore
import SwiftUI

@MainActor
struct ProviderConnectionSection: View {
    let provider: QuotaProvider
    let state: ProviderState?
    let authenticationName: String
    let storesCredential: Bool
    let message: String?
    let messageIsError: Bool
    @Binding var secret: String
    @Binding var executable: URL?
    let chooseExecutable: () -> Void
    let actions: ProviderConnectionActions

    private var lastQuotaReading: String? {
        guard let state, state.connected else { return nil }
        if let date = state.snapshot?.observedAt {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return state.needsAuthentication ? nil : "Waiting for quota"
    }

    var body: some View {
        Section {
            LabeledContent("Status") {
                ConnectionStatusValue(state: state)
            }
            LabeledContent("Sign-in method") {
                Text(authenticationName)
                    .foregroundStyle(.secondary)
            }
            if storesCredential {
                LabeledContent("Credentials") {
                    Label("Login Keychain", systemImage: "key")
                        .foregroundStyle(.secondary)
                }
            }
            if let lastQuotaReading {
                LabeledContent("Last quota reading") {
                    Text(lastQuotaReading)
                        .foregroundStyle(.secondary)
                }
            }

            switch provider.connection {
            case .signedExecutable:
                SignedExecutableConnectionSetup(
                    provider: provider,
                    executable: executable,
                    chooseExecutable: chooseExecutable
                )
            case .apiKey:
                APIKeyConnectionSetup(provider: provider, secret: $secret)
            case .oauth, .browserLogin:
                EmptyView()
            }

            if let message, !message.isEmpty {
                Label(message, systemImage: messageIsError ? "exclamationmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(messageIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Connection")
        } footer: {
            actions
        }
    }
}
