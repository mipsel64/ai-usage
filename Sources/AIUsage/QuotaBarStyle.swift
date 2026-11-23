import SwiftUI

/// Draws the quota bar with SwiftUI shapes. The AppKit-backed `.linear` style drops its `.tint`
/// when the app appearance changes, and the bar falls back to the accent color until its value changes.
struct QuotaBarStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        // ProgressView(value:total:) already pins the value to 0...total.
        let fraction = configuration.fractionCompleted ?? 0
        Capsule()
            .fill(Color.primary.opacity(0.08))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            // Below 6 pt the fill capsule has a smaller radius than the track, so its ends need the track's shape.
            .clipShape(.capsule)
            .frame(height: 6)
    }
}
