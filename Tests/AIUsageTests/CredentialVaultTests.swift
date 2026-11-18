import Foundation
import Testing
import QuotaCore
@testable import AIUsage

struct CredentialVaultTests {
    private let id = ProviderID(rawValue: "claude")

    @Test func storedValueReadsBackFromPrivateFile() async throws {
        try await withVault { vault, directory, _ in
            try vault.store("synthetic-token", for: id)
            #expect(try await vault.read(id, interactive: false) == "synthetic-token")
            #expect(try mode(directory) == 0o700)
            #expect(try mode(directory.appendingPathComponent(id.rawValue)) == 0o600)
            #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }

    @Test func secondStoreReplacesValueWithoutTemporaryFiles() async throws {
        try await withVault { vault, directory, _ in
            try vault.store("first", for: id)
            try vault.store("second", for: id)
            #expect(try await vault.read(id, interactive: false) == "second")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [id.rawValue])
        }
    }

    @Test func symlinkAtTargetIsRefusedAndReplacedWithoutTouchingItsTarget() async throws {
        try await withVault { vault, directory, _ in
            let victim = directory.deletingLastPathComponent().appendingPathComponent("victim")
            try write("victim-content", to: victim, mode: 0o600)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(id.rawValue), withDestinationURL: victim)

            await #expect(throws: VaultError.self) { try await vault.read(id, interactive: false) }
            try vault.store("replacement", for: id)

            #expect(try String(contentsOf: victim, encoding: .utf8) == "victim-content")
            #expect(try await vault.read(id, interactive: false) == "replacement")
        }
    }

    @Test func fileWithGroupOrOtherPermissionIsRefused() async throws {
        for permissions: Int in [0o640, 0o604, 0o620] {
            try await withVault { vault, directory, _ in
                try vault.store("synthetic-token", for: id)
                try FileManager.default.setAttributes([.posixPermissions: permissions],
                                                      ofItemAtPath: directory.appendingPathComponent(id.rawValue).path)
                await #expect(throws: VaultError.self) { try await vault.read(id, interactive: false) }
            }
        }
    }

    @Test func fileLargerThanLimitIsRefused() async throws {
        try await withVault { vault, directory, _ in
            try vault.store(String(repeating: "a", count: 64 * 1024), for: id)
            #expect(try await vault.read(id, interactive: false).count == 64 * 1024)
            try write(String(repeating: "a", count: 64 * 1024 + 1), to: directory.appendingPathComponent(id.rawValue), mode: 0o600)
            await #expect(throws: VaultError.self) { try await vault.read(id, interactive: false) }
        }
    }

    @Test func missingFileWithoutLegacyValueIsNotConfigured() async throws {
        try await withVault { vault, _, legacy in
            await #expect(throws: QuotaError.notConfigured) { try await vault.read(id, interactive: false) }
            #expect(legacy.removals.isEmpty)
        }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let vault = CredentialVault(directory: directory, legacy: nil)
        await #expect(throws: QuotaError.notConfigured) { try await vault.read(id, interactive: false) }
    }

    @Test func unsafeProviderIDsAreRefused() async throws {
        try await withVault { vault, directory, legacy in
            for raw in ["../escape", "a/b", "..", "Claude", "", String(repeating: "a", count: 65)] {
                let unsafe = ProviderID(rawValue: raw)
                #expect(throws: VaultError.self) { try vault.store("synthetic-token", for: unsafe) }
                await #expect(throws: VaultError.self) { try await vault.read(unsafe, interactive: false) }
                #expect(throws: VaultError.self) { try vault.remove(unsafe) }
            }
            #expect(legacy.reads.isEmpty)
            #expect(legacy.removals.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape").path))
        }
    }

    @Test(arguments: [false, true])
    func legacyValueMovesToFileOnFirstRead(allowsInteraction: Bool) async throws {
        try await withVault(legacyValues: [id: "legacy-token"]) { vault, directory, legacy async throws in
            #expect(try await vault.read(id, interactive: allowsInteraction) == "legacy-token")
            #expect(try mode(directory.appendingPathComponent(id.rawValue)) == 0o600)
            #expect(legacy.reads == [allowsInteraction])
            #expect(legacy.removals == [id])

            #expect(try await vault.read(id, interactive: allowsInteraction) == "legacy-token")
            #expect(legacy.reads == [allowsInteraction])
        }
    }

    @Test func failedLegacyReadWritesNothing() async throws {
        try await withVault(legacyValues: [id: "legacy-token"], legacyError: VaultError.keychainMigration) { vault, directory, legacy in
            await #expect(throws: VaultError.keychainMigration) { try await vault.read(id, interactive: false) }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.rawValue).path))
            #expect(legacy.removals.isEmpty)
        }
    }

    @Test func storeNeverUsesLegacyReader() async throws {
        try await withVault(legacyValues: [id: "legacy-token"]) { vault, _, legacy in
            try vault.store("renewed-token", for: id)
            #expect(try await vault.read(id, interactive: false) == "renewed-token")
            #expect(legacy.reads.isEmpty)
            #expect(legacy.removals.isEmpty)
        }
    }

    @Test func removeDeletesFileAndLegacyItem() async throws {
        try await withVault(legacyValues: [id: "legacy-token"]) { vault, directory, legacy in
            try vault.store("synthetic-token", for: id)
            try vault.remove(id)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.rawValue).path))
            #expect(legacy.removals == [id])
            try vault.remove(id)
            #expect(legacy.removals == [id, id])
        }
    }

    private func withVault(legacyValues: [ProviderID: String] = [:], legacyError: (any Error)? = nil,
                           _ body: (CredentialVault, URL, FakeLegacyCredentials) async throws -> Void) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let legacy = FakeLegacyCredentials(values: legacyValues, readError: legacyError)
        try await body(CredentialVault(directory: directory, legacy: legacy), directory, legacy)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialVaultTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("aiusage", isDirectory: true)
    }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int ?? -1) & 0o777
    }

    private func write(_ text: String, to url: URL, mode: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

private final class FakeLegacyCredentials: LegacyCredentialReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderID: String]
    private let readError: (any Error)?
    private var readInteractions: [Bool] = []
    private var removedIDs: [ProviderID] = []

    init(values: [ProviderID: String], readError: (any Error)?) {
        self.values = values
        self.readError = readError
    }

    var reads: [Bool] { withLock { readInteractions } }
    var removals: [ProviderID] { withLock { removedIDs } }

    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        try withLock {
            readInteractions.append(interactive)
            if let readError { throw readError }
            guard let value = values[id] else { throw QuotaError.notConfigured }
            return value
        }
    }

    func remove(_ id: ProviderID) throws {
        withLock {
            removedIDs.append(id)
            values[id] = nil
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
