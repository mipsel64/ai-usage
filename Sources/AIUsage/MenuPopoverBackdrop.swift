import SwiftUI

private let popoverCornerRadius: CGFloat = 24

struct MenuPopoverBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: popoverCornerRadius))
                .background(MenuPopoverWindow(needsMaterial: false))
        } else {
            MenuPopoverWindow(needsMaterial: !reduceTransparency)
                .background {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: popoverCornerRadius, style: .continuous))
        }
    }
}
