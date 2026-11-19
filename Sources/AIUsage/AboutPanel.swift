import AppKit
import SwiftUI

private let repositoryURL = URL(string: "https://github.com/mipsel64/ai-usage")!

struct AboutPanel: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        if let build = info?["CFBundleVersion"] as? String, build != short {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
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
                            Text(version)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Link("GitHub repository", destination: repositoryURL)
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
