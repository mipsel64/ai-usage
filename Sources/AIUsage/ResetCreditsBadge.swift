import SwiftUI

struct ResetCreditsBadge: View {
    let count: Int

    var body: some View {
        Text("\(count) reset\(count == 1 ? "" : "s")")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: .capsule)
    }
}
