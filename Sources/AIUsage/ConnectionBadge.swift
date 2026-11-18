import SwiftUI

struct ConnectionBadge: View {
    let title: String
    let status: Status

    enum Status {
        case connected, waiting, disconnected, attention

        var color: Color {
            switch self {
            case .connected: .green
            case .waiting: .blue
            case .disconnected: .secondary
            case .attention: .orange
            }
        }

        var symbol: String {
            switch self {
            case .connected: "checkmark.circle.fill"
            case .waiting: "clock.fill"
            case .disconnected: "circle"
            case .attention: "exclamationmark.circle.fill"
            }
        }
    }

    var body: some View {
        Label(title, systemImage: status.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(status.color)
            .labelStyle(.titleAndIcon)
    }
}
