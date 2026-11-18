import AppKit
import Darwin
import SwiftUI

// Command Line Tools ship the State wrapper but not the Xcode 27 State macro plug-in.
private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
struct ClaudeDesktopSetupView: View {
    @ViewState private var workspaceURL: URL?
    @ViewState private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up the quota-feed plugin in Claude Desktop. You sign in there. AI Usage receives quota readings, not your credentials.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(workspaceURL == nil ? "Prepare Setup Folder and Show in Finder…" : "Prepare a New Setup Folder…") {
                prepareWorkspace()
            }

            if let workspaceURL {
                Text(workspaceURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show Setup Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([workspaceURL])
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("1. In Claude Desktop, open Code, choose Local, then Open folder. Drag the setup folder from Finder into the folder picker and open it.")
                Text("2. Review and trust the setup folder. It lists the plugin bundled with this app.")
                Text("3. Choose + → Add plugins (or Browse plugins), select quota-feed, and install it for your user account.")
                Text("4. Start monitoring below. The feed updates after eligible local Code turns.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Link("Download Claude Desktop", destination: ClaudeDesktopSetup.downloadURL)

            Text("After disconnecting, AI Usage stops reading the feed. To stop capture, open Plugins in Claude Desktop and disable or uninstall quota-feed; disconnecting here does not change the plugin.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private func prepareWorkspace() {
        errorMessage = nil
        do {
            let url = try ClaudeDesktopSetup.prepareWorkspace()
            workspaceURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum ClaudeDesktopSetup {
    static let downloadURL = URL(string: "https://claude.ai/download")!

    static func prepareWorkspace() throws -> URL {
        let marketplace = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ClaudeMarketplace", isDirectory: true)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try prepareWorkspace(marketplace: marketplace, applicationSupport: support)
    }

    static func prepareWorkspace(marketplace: URL, applicationSupport: URL) throws -> URL {
        let fileManager = FileManager.default
        let marketplaceValues = try marketplace.resourceValues(forKeys: [.isDirectoryKey])
        guard marketplaceValues.isDirectory == true else {
            throw ActionError("This AI Usage build does not contain its Claude marketplace resource. Reinstall the app and try again.")
        }

        let supportDirectory = applicationSupport.appendingPathComponent("ai-usage", isDirectory: true)
        try makePrivateDirectory(supportDirectory, fileManager: fileManager)
        let feed = supportDirectory.appendingPathComponent("claude-desktop.json")
        try feed.withUnsafeFileSystemRepresentation { path in
            let invalidFeed = ActionError("Cannot prepare the private quota file. Check the AI Usage folder in Application Support.")
            guard let path else { throw invalidFeed }
            let fd = open(path, O_CREAT | O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw invalidFeed }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                  info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw invalidFeed }
        }

        // A new folder avoids overwriting settings the user may have changed.
        let workspace = supportDirectory.appendingPathComponent(
            "Claude Desktop Setup \(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let claudeDirectory = workspace.appendingPathComponent(".claude", isDirectory: true)
        try fileManager.createDirectory(
            at: claudeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let settings: [String: Any] = [
            "extraKnownMarketplaces": [
                "ai-usage-local": [
                    "source": [
                        "source": "directory",
                        "path": marketplace.path,
                    ],
                ],
            ],
        ]
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        try data.write(to: settingsURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
        return workspace
    }

    private static func makePrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            try requireRealDirectory(url)
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try requireRealDirectory(url)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func requireRealDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ActionError("The AI Usage support location is not a regular folder. Move or rename the existing item at \(url.path), then try again.")
        }
    }
}
