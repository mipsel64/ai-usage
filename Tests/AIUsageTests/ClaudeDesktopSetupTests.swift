import Foundation
import Testing
@testable import AIUsage

struct ClaudeDesktopSetupTests {
    @Test func setupDeclaresOnlyTheBundledMarketplaceAndPreservesEarlierWorkspaces() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let marketplace = root.appendingPathComponent("Bundled Marketplace", isDirectory: true)
        try fm.createDirectory(at: marketplace, withIntermediateDirectories: true)
        let workspace = try ClaudeDesktopSetup.prepareWorkspace(marketplace: marketplace, applicationSupport: root)
        let settings = workspace.appendingPathComponent(".claude/settings.json")
        let json = try JSONDecoder().decode([String: [String: [String: [String: String]]]].self, from: Data(contentsOf: settings))
        #expect(json == ["extraKnownMarketplaces": ["ai-usage-local": ["source": ["source": "directory", "path": marketplace.path]]]])
        let attributes = try fm.attributesOfItem(atPath: workspace.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let feed = workspace.deletingLastPathComponent().appendingPathComponent("claude-desktop.json")
        let feedAttributes = try fm.attributesOfItem(atPath: feed.path)
        #expect((feedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reading = Data("existing observation".utf8)
        try reading.write(to: feed)
        let userEdit = Data("user edit".utf8)
        try userEdit.write(to: settings)
        let another = try ClaudeDesktopSetup.prepareWorkspace(marketplace: marketplace, applicationSupport: root)
        #expect(another != workspace)
        #expect(try Data(contentsOf: settings) == userEdit)
        #expect(try Data(contentsOf: feed) == reading)
    }

    @Test func setupRefusesLinkedSupportDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("ai-usage"), withDestinationURL: outside)
        #expect(throws: ActionError.self) { try ClaudeDesktopSetup.prepareWorkspace(marketplace: outside, applicationSupport: root) }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
