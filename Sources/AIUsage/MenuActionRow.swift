import SwiftUI

// Command Line Tools require the property wrapper instead of the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint(shortcut.map { "Keyboard shortcut \($0)" } ?? "")
    }
}
