import SwiftUI

struct AccountPortalFailure: View {
    let message: String
    let copiedAddress: Bool
    let tryAgain: () -> Void
    let copyAddress: () -> Void

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Try Again", action: tryAgain)
                Button(copiedAddress ? "Copied" : "Copy Address", action: copyAddress)
            }
            .controlSize(.small)
        }
    }
}
