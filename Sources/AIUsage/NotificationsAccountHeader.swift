import SwiftUI

struct NotificationsAccountHeader: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "bell")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("AI Usage tells you when a quota window resets or runs low.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
