import Foundation
import QuotaCore

enum VaultError: LocalizedError {
    /// The credential file cannot be read or written, or it is not private to the current user.
    case inaccessible
    /// A credential from an earlier version cannot be read from the login Keychain to move it to a file.
    case keychainMigration

    var errorDescription: String? {
        switch self {
        case .inaccessible:
            "Cannot read or save the sign-in. The folder \(CredentialVault.displayDirectory) must be private to your user."
        case .keychainMigration:
            "Cannot move the sign-in out of the login Keychain. Refresh this provider from the menu and allow access."
        }
    }
}

protocol CredentialVaulting: Sendable {
    func store(_ value: String, for id: ProviderID) throws
    func read(_ id: ProviderID, interactive: Bool) async throws -> String
    func remove(_ id: ProviderID) throws
}

/// Keeps each credential in a private file `~/.config/aiusage/<provider id>` and moves Keychain items there on first read.
struct CredentialVault: CredentialVaulting {
    static let homeRelativeDirectory = ".config/aiusage"
    static let displayDirectory = "~/\(homeRelativeDirectory)"
    private static let maximumFileSize = 64 * 1024
    private static let maximumIDLength = 64
    private static let privateFileMode: mode_t = 0o600
    private static let privateDirectoryMode = 0o700

    private let directory: URL
    private let legacy: (any LegacyCredentialReading)?

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(homeRelativeDirectory, isDirectory: true),
         legacy: (any LegacyCredentialReading)? = LegacyKeychainCredentials()) {
        self.directory = directory
        self.legacy = legacy
    }

    func store(_ value: String, for id: ProviderID) throws {
        let target = try file(for: id)
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: Self.privateDirectoryMode])
            } catch {
                throw VaultError.inaccessible
            }
            // Best effort: a volume without this attribute must not stop a renewed sign-in from being saved.
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var backupTarget = directory
            try? backupTarget.setResourceValues(excluded)
        }
        let temporary = directory.appendingPathComponent(".\(id.rawValue).\(UUID().uuidString)", isDirectory: false)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, Self.privateFileMode)
        guard descriptor >= 0 else { throw VaultError.inaccessible }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(value.utf8))
            try handle.synchronize()
            try handle.close()
            // rename replaces a symlink at the target instead of following it.
            guard rename(temporary.path, target.path) == 0 else { throw VaultError.inaccessible }
        } catch {
            unlink(temporary.path)
            throw VaultError.inaccessible
        }
    }

    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        let target = try file(for: id)
        if let value = try Self.readPrivateFile(target) { return value }
        guard let legacy else { throw QuotaError.notConfigured }
        let value: String
        do {
            value = try await legacy.read(id, interactive: interactive)
        } catch {
            // A concurrent read can move the item first and remove it from the Keychain.
            if let value = try Self.readPrivateFile(target) { return value }
            throw error
        }
        try store(value, for: id)
        try? legacy.remove(id)
        return value
    }

    func remove(_ id: ProviderID) throws {
        let target = try file(for: id)
        guard unlink(target.path) == 0 || errno == ENOENT else { throw VaultError.inaccessible }
        try? legacy?.remove(id)
    }

    private func file(for id: ProviderID) throws -> URL {
        let name = id.rawValue.utf8
        guard (1...Self.maximumIDLength).contains(name.count),
              name.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                  || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                  || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }) else { throw VaultError.inaccessible }
        return directory.appendingPathComponent(id.rawValue, isDirectory: false)
    }

    /// Returns nil when the file does not exist.
    private static func readPrivateFile(_ url: URL) throws -> String? {
        // O_NONBLOCK keeps a FIFO at the path from blocking the open.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw VaultError.inaccessible
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & (S_IRWXG | S_IRWXO) == 0,
              info.st_size <= maximumFileSize,
              let data = try? handle.read(upToCount: maximumFileSize + 1) ?? Data(),
              data.count <= maximumFileSize,
              let value = String(data: data, encoding: .utf8) else { throw VaultError.inaccessible }
        return value
    }
}
