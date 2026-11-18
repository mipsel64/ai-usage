import SwiftUI

struct AIUsageAppIcon: View {
    var size: CGFloat = 42

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(.linearGradient(
                colors: [Color(red: 0.22, green: 0.76, blue: 0.72), Color(red: 0.16, green: 0.42, blue: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
