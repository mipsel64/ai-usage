import QuotaCore
import SwiftUI

struct APIKeyConnectionSetup: View {
    let provider: QuotaProvider
    @Binding var secret: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter a new \(provider.displayName) API key to connect or reconnect. It is never prefilled.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("\(provider.displayName) API key", text: $secret)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }
}
