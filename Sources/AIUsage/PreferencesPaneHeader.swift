import SwiftUI

struct PreferencesPaneHeader<Icon: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    let icon: Icon
    let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                icon
                    .frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                accessory
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)
            Divider()
        }
    }
}
