import SwiftUI

struct AccountField: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
    }
}
