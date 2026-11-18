import SwiftUI

private let popoverCornerRadius: CGFloat = 24

struct MenuPopoverBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            // macOS 26 draws the panel background and rim itself; a second shape doubles the rim.
            EmptyView()
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
