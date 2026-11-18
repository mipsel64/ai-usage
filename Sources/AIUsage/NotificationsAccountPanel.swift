import SwiftUI
import QuotaCore

@MainActor
struct NotificationsAccountPanel: View {
    let store: UsageStore

    private var notificationsEnabled: Binding<Bool> {
        Binding(
            get: { store.notificationsEnabled },
            set: { enabled in
                Task { await store.setNotifications(enabled) }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                NotificationsAccountHeader()
            }

            Section {
                Toggle("Notify me when a quota resets or runs low", isOn: notificationsEnabled)
                    .toggleStyle(.switch)
                if !store.notificationStatus.isEmpty {
                    Label(store.notificationStatus, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("AI Usage reads connected subscriptions about once a minute. Low-quota alerts are sent when a window goes below \(QuotaSnapshot.lowQuotaThresholds.map { "\($0)%" }.joined(separator: " and ")). Checks and alerts stop when you quit the app.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
