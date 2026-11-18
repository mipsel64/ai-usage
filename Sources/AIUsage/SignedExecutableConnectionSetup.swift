import QuotaCore
import SwiftUI

struct SignedExecutableConnectionSetup: View {
    let provider: QuotaProvider
    let executable: URL?
    let chooseExecutable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Choose the signed native \(provider.displayName) executable, not an npm wrapper. Select only the official executable that you trust.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Choose \(provider.displayName) Executable…", action: chooseExecutable)
                if let executable {
                    Text(executable.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let executable {
                Text(executable.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
