import SwiftUI

struct ConnectionStatusValue: View {
    let state: ProviderState?

    private var title: String {
        if state?.needsAuthentication == true { return "Sign-in required" }
        return state?.connected == true ? "Connected" : "Not connected"
    }

    private var color: Color {
        if state?.needsAuthentication == true { return .orange }
        return state?.connected == true ? .green : .secondary
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
