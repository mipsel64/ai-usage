import QuotaCore
import SwiftUI

@MainActor
struct PreferencesSidebar: View {
    let store: UsageStore
    @Binding var selection: PreferencesSelection?

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
                            SignInRequiredDot()
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .tag(PreferencesSelection.provider(provider.id))
                }
            }

            Section("System") {
                Label("General", systemImage: "gearshape")
                    .tag(PreferencesSelection.general)
                Label("Notifications", systemImage: "bell")
                    .tag(PreferencesSelection.notifications)
                Label("About", systemImage: "info.circle")
                    .tag(PreferencesSelection.about)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(220)
        .frame(width: 220)
        .toolbar(removing: .sidebarToggle)
    }
}
