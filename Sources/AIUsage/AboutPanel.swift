import AppKit
import SwiftUI

private let repositoryURL = URL(string: "https://github.com/mipsel64/ai-usage")!

struct AboutPanel: View {
    /// `<version>+<commit>`, only the version without a commit, and nil outside a bundle.
    nonisolated static func version(short: String?, commit: String?) -> String? {
        guard let short else { return nil }
        guard let commit else { return short }
        return "\(short)+\(commit)"
    }

    private var version: String? {
        let info = Bundle.main.infoDictionary
        return Self.version(
            short: info?["CFBundleShortVersionString"] as? String,
            commit: info?["AIUsageCommit"] as? String
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            PreferencesPaneHeader(
                title: "About",
                subtitle: "Version and source of AI Usage."
            ) {
                PreferencesSymbol(systemImage: "info.circle")
            }

            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("AI Usage")
                                .font(.title2.bold())
                            versionLine
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link("GitHub repository", destination: repositoryURL)
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var versionLine: some View {
        if let version {
            HStack(spacing: 4) {
                Text("Version")
                Text(version)
                    .monospaced()
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Version \(version)")
        } else {
            Text("Development build")
        }
    }
}
