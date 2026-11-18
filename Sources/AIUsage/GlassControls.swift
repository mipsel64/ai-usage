import SwiftUI

private struct UsageActionStyle: ViewModifier {
    let prominent: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct UsageGlassGroup: ViewModifier {
    let spacing: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

public extension View {
    /// Styles an action with native Liquid Glass when available and appropriate.
    func usageActionStyle(prominent: Bool = false) -> some View {
        modifier(UsageActionStyle(prominent: prominent))
    }

    /// Coordinates adjacent Liquid Glass controls without grouping older or reduced-transparency UI.
    func usageGlassGroup(spacing: CGFloat = 8) -> some View {
        modifier(UsageGlassGroup(spacing: spacing))
    }
}
