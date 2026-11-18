import SwiftUI

struct ProviderConnectionActions: View {
    let disconnectTitle: String?
    let connectTitle: String
    let isBusy: Bool
    let canConnect: Bool
    let connectIsProminent: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 12)
            if let disconnectTitle {
                Button(disconnectTitle, role: .destructive, action: disconnect)
                    .usageActionStyle()
                    .disabled(isBusy)
            }
            Button(connectTitle, action: connect)
                .usageActionStyle(prominent: connectIsProminent)
                .disabled(isBusy || !canConnect)
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
        }
    }
}
