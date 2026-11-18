import QuotaCore
import SwiftUI

struct QuotaWindowRow: View {
    let window: QuotaWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let resetAt = window.resetAt {
                    Text(resetCountdown(from: now, to: resetAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))%")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }

            ProgressView(value: window.remainingPercent, total: 100)
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(UsageVisuals.quotaColor(remaining: window.remainingPercent))
                .accessibilityLabel("\(window.title) remaining quota")
                .accessibilityValue("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1)))) percent")
        }
    }

    private func hasUsableResetInterval(_ interval: TimeInterval) -> Bool {
        interval.isFinite && interval > -Double(Int.max) && interval < Double(Int.max)
    }

    private func resetCountdown(from now: Date, to resetAt: Date) -> String {
        let interval = resetAt.timeIntervalSince(now)
        guard hasUsableResetInterval(interval) else { return "Reset unavailable" }
        guard interval > 0 else { return "Reset due" }
        let totalMinutes = max(1, Int(ceil(interval / 60)))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "Resets in \(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }
}
