import SwiftUI

struct MenuPopoverBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
                .background(MenuPopoverWindow(usesGlass: true, reduceTransparency: false))
        } else {
            MenuPopoverWindow(usesGlass: false, reduceTransparency: reduceTransparency)
        }
    }
}
