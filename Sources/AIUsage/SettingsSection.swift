import SwiftUI

struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(UsagePanelColors.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(UsagePanelColors.border, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        }
    }
}
