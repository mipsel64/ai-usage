import Foundation
import QuotaCore

enum VaultError: LocalizedError {
    /// The credential file cannot be read or written, or it is not private to the current user.
    case inaccessible
    /// A credential from an earlier version cannot be read from the login Keychain to move it to a file.
    case keychainMigration
    /// A credential from an earlier version cannot be deleted from the login Keychain.
    case keychainRemoval

    var errorDescription: String? {
        switch self {
        case .inaccessible:
            "Cannot read or save the sign-in. The folder \(CredentialVault.displayDirectory) must be private to your user."
        case .keychainMigration:
            "Cannot move the sign-in out of the login Keychain. Refresh this provider from the menu and allow access."
        case .keychainRemoval:
            "Cannot delete the old sign-in from the login Keychain. Unlock the Keychain and try again."
        }
    }
}

protocol CredentialVaulting: Sendable {
    func store(_ value: String, for id: ProviderID) throws
    func read(_ id: ProviderID, interactive: Bool) async throws -> String
    func remove(_ id: ProviderID) throws
}

/// Keeps each credential in a private file `~/.config/aiusage/<provider id>` and moves Keychain items there on first read.
final class CredentialVault: CredentialVaulting, @unchecked Sendable {
    static let homeRelativeDirectory = ".config/aiusage"
    static let displayDirectory = "~/\(homeRelativeDirectory)"
    private static let maximumFileSize = 64 * 1024
    private static let maximumIDLength = 64
    private static let privateFileMode: mode_t = 0o600
    private static let privateDirectoryMode: mode_t = 0o700

    private let directory: URL
    private let legacy: (any LegacyCredentialReading)?
    private let lock = NSLock()
    /// Counts the changes of each provider file, so that a Keychain move that waited for a dialog never overwrites a later store or remove.
    /// Guarded by `lock`.
    private var changes: [String: Int] = [:]

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(homeRelativeDirectory, isDirectory: true),
         legacy: (any LegacyCredentialReading)? = LegacyKeychainCredentials()) {
        self.directory = directory
        self.legacy = legacy
    }

    func store(_ value: String, for id: ProviderID) throws {
        let name = try Self.fileName(for: id)
        let data = try Self.contents(value)
        try lock.withLock {
            try write(data, name: name)
            changes[name, default: 0] += 1
        }
    }

    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        let name = try Self.fileName(for: id)
        let (stored, observed) = try lock.withLock { (try readFile(name), changes[name, default: 0]) }
        if let stored { return stored }
        guard let legacy else { throw QuotaError.notConfigured }
        let value: String
        do {
            value = try await legacy.read(id, interactive: interactive)
        } catch {
            // A concurrent read can move the item first and remove it from the Keychain.
            if let stored = try lock.withLock({ try readFile(name) }) { return stored }
            throw error
        }
        return try lock.withLock {
            guard changes[name, default: 0] == observed else {
                guard let stored = try readFile(name) else { throw QuotaError.notConfigured }
                return stored
            }
            let data = try Self.contents(value)
            try write(data, name: name)
            changes[name, default: 0] += 1
            try? legacy.remove(id)
            return value
        }
    }

    func remove(_ id: ProviderID) throws {
        let name = try Self.fileName(for: id)
        try lock.withLock {
            let directory = try openDirectory(create: false)
            defer { if let directory { close(directory) } }
            try legacy?.remove(id)
            changes[name, default: 0] += 1
            guard let directory else { return }
            try Self.removeTemporaryFiles(of: name, in: directory)
            guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw VaultError.inaccessible }
        }
    }

    private static func fileName(for id: ProviderID) throws -> String {
        let name = id.rawValue.utf8
        guard (1...maximumIDLength).contains(name.count),
              name.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
                  || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                  || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }) else { throw VaultError.inaccessible }
        return id.rawValue
    }

    /// Deletes the temporary files `.<name>.<UUID>.tmp` that an interrupted store of one provider left. Call with `lock` held.
    private static func removeTemporaryFiles(of name: String, in directory: Int32) throws {
        let listing = dup(directory)
        guard listing >= 0 else { throw VaultError.inaccessible }
        guard let stream = fdopendir(listing) else {
            close(listing)
            throw VaultError.inaccessible
        }
        defer { closedir(stream) }
        rewinddir(stream)
        let prefix = ".\(name).", suffix = ".tmp"
        var stale: [String] = []
        while true {
            // readdir returns nil both at the end and on an error; only errno tells them apart.
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw VaultError.inaccessible }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let entryName = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            guard entryName.count > prefix.count + suffix.count, entryName.hasPrefix(prefix), entryName.hasSuffix(suffix),
                  UUID(uuidString: String(entryName.dropFirst(prefix.count).dropLast(suffix.count))) != nil else { continue }
            stale.append(entryName)
        }
        for entry in stale {
            guard unlinkat(directory, entry, 0) == 0 || errno == ENOENT else { throw VaultError.inaccessible }
        }
    }

    /// Refuses a value that `read` would refuse, before any file changes.
    private static func contents(_ value: String) throws -> Data {
        let data = Data(value.utf8)
        guard data.count <= maximumFileSize else { throw VaultError.inaccessible }
        return data
    }

    /// F_FULLFSYNC reaches the storage device; plain fsync is the fallback where it is not supported.
    private static func flush(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_FULLFSYNC) != -1 || fsync(descriptor) == 0
    }

    /// Opens the directory without following a symlink, and requires that it is private to the current user.
    /// Returns nil when it does not exist and `create` is false. Call with `lock` held.
    private func openDirectory(create: Bool) throws -> Int32? {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var descriptor = open(directory.path, flags)
        var created = false
        if descriptor < 0, errno == ENOENT {
            guard create else { return nil }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: Int(Self.privateDirectoryMode)])
            } catch {
                throw VaultError.inaccessible
            }
            descriptor = open(directory.path, flags)
            created = true
        }
        guard descriptor >= 0 else { throw VaultError.inaccessible }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & (S_IRWXG | S_IRWXO) == 0 || fchmod(descriptor, Self.privateDirectoryMode) == 0 else {
            close(descriptor)
            throw VaultError.inaccessible
        }
        if created { protectNewDirectory(descriptor) }
        return descriptor
    }

    /// Best effort: a failure here must not stop a renewed sign-in from being saved.
    private func protectNewDirectory(_ descriptor: Int32) {
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var backupTarget = directory
        try? backupTarget.setResourceValues(excluded)
        // ~/.config is often a dotfiles Git work tree; keep the credentials out of `git add -A`.
        let ignore = openat(descriptor, ".gitignore", O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, Self.privateFileMode)
        guard ignore >= 0 else { return }
        let handle = FileHandle(fileDescriptor: ignore, closeOnDealloc: true)
        try? handle.write(contentsOf: Data("*\n".utf8))
        try? handle.close()
    }

    /// Call with `lock` held.
    private func write(_ data: Data, name: String) throws {
        guard let directory = try openDirectory(create: true) else { throw VaultError.inaccessible }
        defer { close(directory) }
        // A crash can leave temporary files of an earlier store; a unique name keeps another writer's file from being published.
        try Self.removeTemporaryFiles(of: name, in: directory)
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, Self.privateFileMode)
        guard descriptor >= 0 else { throw VaultError.inaccessible }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard Self.flush(descriptor) else { throw VaultError.inaccessible }
            try handle.close()
            // renameat replaces a symlink at the target instead of following it.
            guard renameat(directory, temporary, directory, name) == 0 else { throw VaultError.inaccessible }
            // Best effort: the file already holds the new value, and some volumes cannot flush a directory.
            _ = Self.flush(directory)
        } catch {
            unlinkat(directory, temporary, 0)
            throw VaultError.inaccessible
        }
    }

    /// Returns nil when the file or its directory does not exist. Call with `lock` held.
    private func readFile(_ name: String) throws -> String? {
        guard let directory = try openDirectory(create: false) else { return nil }
        defer { close(directory) }
        // O_NONBLOCK keeps a FIFO at the path from blocking the open.
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
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
              info.st_size <= Self.maximumFileSize,
              let data = try? handle.read(upToCount: Self.maximumFileSize + 1) ?? Data(),
              data.count <= Self.maximumFileSize,
              let value = String(data: data, encoding: .utf8) else { throw VaultError.inaccessible }
        return value
    }
}
