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
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [".gitignore", id.rawValue])
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

    @Test func newDirectoryTellsGitToIgnoreItsFiles() async throws {
        try await withVault { vault, directory, _ in
            try vault.store("synthetic-token", for: id)
            #expect(try String(contentsOf: directory.appendingPathComponent(".gitignore"), encoding: .utf8) == "*\n")
        }
    }

    @Test func symlinkAtDirectoryIsRefused() async throws {
        try await withVault(legacyValues: [id: "legacy-token"]) { vault, directory, legacy in
            let elsewhere = directory.deletingLastPathComponent().appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)

            #expect(throws: VaultError.inaccessible) { try vault.store("synthetic-token", for: id) }
            await #expect(throws: VaultError.inaccessible) { try await vault.read(id, interactive: false) }
            #expect(throws: VaultError.inaccessible) { try vault.remove(id) }

            #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
            #expect(legacy.reads.isEmpty)
            #expect(legacy.removals.isEmpty)
        }
    }

    @Test func existingDirectoryWithOpenPermissionsIsMadePrivate() async throws {
        try await withVault { vault, directory, _ in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            try vault.store("synthetic-token", for: id)
            #expect(try mode(directory) == 0o700)
            #expect(try await vault.read(id, interactive: false) == "synthetic-token")
        }
    }

    @Test func staleTemporaryFilesOfOneProviderAreDeleted() async throws {
        try await withVault { vault, directory, _ in
            let stale = directory.appendingPathComponent(".\(id.rawValue).\(UUID().uuidString).tmp")
            let otherProvider = directory.appendingPathComponent(".\(id.rawValue)-max.\(UUID().uuidString).tmp")
            try write("stale-token", to: stale, mode: 0o600)
            try write("other-token", to: otherProvider, mode: 0o600)

            try vault.store("synthetic-token", for: id)
            #expect(!FileManager.default.fileExists(atPath: stale.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasSuffix(".tmp") } == [otherProvider.lastPathComponent])
            #expect(try await vault.read(id, interactive: false) == "synthetic-token")

            try write("stale-token", to: stale, mode: 0o600)
            try vault.remove(id)
            #expect(!FileManager.default.fileExists(atPath: stale.path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.rawValue).path))
            #expect(FileManager.default.fileExists(atPath: otherProvider.path))
        }
    }

    @Test func temporaryCleanupKeepsNamesTheVaultDidNotCreate() async throws {
        try await withVault { vault, directory, _ in
            let foreignFile = directory.appendingPathComponent(".\(id.rawValue).backup.tmp")
            let foreignDirectory = directory.appendingPathComponent(".\(id.rawValue).dir.tmp", isDirectory: true)
            let stale = directory.appendingPathComponent(".\(id.rawValue).\(UUID().uuidString).tmp")
            try write("foreign-content", to: foreignFile, mode: 0o600)
            try FileManager.default.createDirectory(at: foreignDirectory, withIntermediateDirectories: true)
            try write("stale-token", to: stale, mode: 0o600)

            try vault.store("synthetic-token", for: id)
            #expect(!FileManager.default.fileExists(atPath: stale.path))
            try write("stale-token", to: stale, mode: 0o600)
            try vault.remove(id)

            #expect(!FileManager.default.fileExists(atPath: stale.path))
            #expect(try String(contentsOf: foreignFile, encoding: .utf8) == "foreign-content")
            #expect(FileManager.default.fileExists(atPath: foreignDirectory.path))
        }
    }

    @Test func oversizedValueIsRefusedBeforeTheFileChanges() async throws {
        try await withVault { vault, _, _ in
            try vault.store("old-token", for: id)
            #expect(throws: VaultError.inaccessible) { try vault.store(String(repeating: "a", count: 64 * 1024 + 1), for: id) }
            #expect(try await vault.read(id, interactive: false) == "old-token")
        }
    }

    @Test func oversizedLegacyValueStaysInKeychain() async throws {
        try await withVault(legacyValues: [id: String(repeating: "a", count: 64 * 1024 + 1)]) { vault, directory, legacy in
            await #expect(throws: VaultError.inaccessible) { try await vault.read(id, interactive: false) }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.rawValue).path))
            #expect(legacy.removals.isEmpty)
        }
    }

    @Test func failedKeychainDeleteStopsRemove() async throws {
        try await withVault(legacyRemoveError: VaultError.keychainRemoval) { vault, _, _ in
            try vault.store("synthetic-token", for: id)
            #expect(throws: VaultError.keychainRemoval) { try vault.remove(id) }
            #expect(try await vault.read(id, interactive: false) == "synthetic-token")
        }
    }

    @Test func keychainMoveDoesNotOverwriteAReconnect() async throws {
        let gate = Gate()
        let id = id
        try await withVault(legacyValues: [id: "old-token"], gates: [id: gate]) { vault, directory, legacy in
            let moved = Task { try await vault.read(id, interactive: false) }
            await gate.waitUntilEntered()
            try vault.store("new-token", for: id)
            await gate.open()

            #expect(try await moved.value == "new-token")
            #expect(try String(contentsOf: directory.appendingPathComponent(id.rawValue), encoding: .utf8) == "new-token")
            #expect(legacy.removals.isEmpty)
        }
    }

    @Test func keychainMoveDoesNotUndoADisconnect() async throws {
        let gate = Gate()
        let id = id
        try await withVault(legacyValues: [id: "old-token"], gates: [id: gate]) { vault, directory, legacy in
            let moved = Task { try await vault.read(id, interactive: false) }
            await gate.waitUntilEntered()
            try vault.remove(id)
            await gate.open()

            await #expect(throws: QuotaError.notConfigured) { try await moved.value }
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(id.rawValue).path))
            #expect(legacy.removals == [id])
        }
    }

    @Test func keychainMoveOfOneProviderDoesNotCancelAnother() async throws {
        let first = id
        let second = ProviderID(rawValue: "codex")
        let firstGate = Gate()
        let secondGate = Gate()
        try await withVault(legacyValues: [first: "first-token", second: "second-token"],
                            gates: [first: firstGate, second: secondGate]) { vault, directory, _ async throws in
            let firstMove = Task { try await vault.read(first, interactive: false) }
            let secondMove = Task { try await vault.read(second, interactive: false) }
            await firstGate.waitUntilEntered()
            await secondGate.waitUntilEntered()
            await firstGate.open()
            #expect(try await firstMove.value == "first-token")
            await secondGate.open()

            #expect(try await secondMove.value == "second-token")
            #expect(try String(contentsOf: directory.appendingPathComponent(second.rawValue), encoding: .utf8) == "second-token")
        }
    }

    @Test func failedStoreDoesNotCancelAWaitingKeychainMove() async throws {
        let gate = Gate()
        let id = id
        try await withVault(legacyValues: [id: "legacy-token"], gates: [id: gate]) { vault, directory, _ in
            let moved = Task { try await vault.read(id, interactive: false) }
            await gate.waitUntilEntered()
            let elsewhere = directory.deletingLastPathComponent().appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
            #expect(throws: VaultError.inaccessible) { try vault.store("new-token", for: id) }
            try FileManager.default.removeItem(at: directory)
            await gate.open()

            #expect(try await moved.value == "legacy-token")
            #expect(try String(contentsOf: directory.appendingPathComponent(id.rawValue), encoding: .utf8) == "legacy-token")
        }
    }

    private func withVault(legacyValues: [ProviderID: String] = [:], legacyError: (any Error)? = nil,
                           legacyRemoveError: (any Error)? = nil, gates: [ProviderID: Gate] = [:],
                           _ body: (CredentialVault, URL, FakeLegacyCredentials) async throws -> Void) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let legacy = FakeLegacyCredentials(values: legacyValues, readError: legacyError, removeError: legacyRemoveError, gates: gates)
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
    private let removeError: (any Error)?
    private let gates: [ProviderID: Gate]
    private var readInteractions: [Bool] = []
    private var removedIDs: [ProviderID] = []

    init(values: [ProviderID: String], readError: (any Error)?, removeError: (any Error)?, gates: [ProviderID: Gate]) {
        self.values = values
        self.readError = readError
        self.removeError = removeError
        self.gates = gates
    }

    var reads: [Bool] { withLock { readInteractions } }
    var removals: [ProviderID] { withLock { removedIDs } }

    /// Takes the value first and then waits at the gate, like a Keychain read that waits for a dialog.
    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        let result: Result<String, any Error> = withLock {
            readInteractions.append(interactive)
            if let readError { return .failure(readError) }
            guard let value = values[id] else { return .failure(QuotaError.notConfigured) }
            return .success(value)
        }
        await gates[id]?.enter()
        return try result.get()
    }

    func remove(_ id: ProviderID) throws {
        try withLock {
            if let removeError { throw removeError }
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

private actor Gate {
    private var entered = false
    private var released = false
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        enterWaiter?.resume()
        enterWaiter = nil
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enterWaiter = $0 } }
    }

    func open() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
