import QuotaCore
import SwiftUI

@MainActor
struct AccountsSidebar: View {
    let store: UsageStore
    @Binding var selection: AccountSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Subscriptions") {
                ForEach(store.providers) { provider in
                    HStack(spacing: 10) {
                        ProviderAvatar(provider: provider, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                            if store.states[provider.id]?.connected != true {
                                Text("Not connected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if store.states[provider.id]?.needsAuthentication == true {
                            Circle()
                                .fill(.orange)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("Sign-in required")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .tag(AccountSelection.provider(provider.id))
                }
            }

            Label("Notifications", systemImage: "bell")
                .tag(AccountSelection.notifications)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(220)
        .frame(width: 220)
        .toolbar(removing: .sidebarToggle)
    }
}
