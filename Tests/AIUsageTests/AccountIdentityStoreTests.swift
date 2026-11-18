import Foundation
import Testing
import QuotaCore
@testable import AIUsage

@MainActor
struct AccountIdentityStoreTests {
    private let id = ProviderID(rawValue: "identity-store-test")
    private let url = URL(string: "https://example.invalid/account")!
    private let snapshot = QuotaSnapshot(
        windows: [.init(id: "week", title: "Weekly", remainingPercent: 80, resetAt: nil)], observedAt: .now
    )
    private let identity = AccountIdentity(email: "user@example.com", name: "Alice")

    @Test func connectStoresIdentityAndRefreshDoesNotReadItAgain() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let reads = AccountReadCounter()
        let provider = makeProvider { _ in
            await reads.record()
            return identity
        }
        let vault = AccountMemoryVault()
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        try await store.connect(id, secret: "synthetic-secret")
        await waitForAccountRead(store)
        #expect(store.states[id]?.account == identity)
        #expect(await reads.count == 1)
        await store.refresh(id)
        #expect(store.states[id]?.account == identity)
        #expect(await reads.count == 1)
    }

    @Test func identityFailureNeverFailsConnectOrChangesQuotaState() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = makeProvider { _ in nil }
        let store = UsageStore(providers: [provider], defaults: defaults, vault: AccountMemoryVault())
        try await store.connect(id, secret: "synthetic-secret")
        await waitForAccountRead(store)
        #expect(store.states[id]?.connected == true)
        #expect(store.states[id]?.snapshot == snapshot)
        #expect(store.states[id]?.account == nil)
        #expect(store.states[id]?.message == nil)
        #expect(store.states[id]?.needsAuthentication == false)
    }

    @Test func browserIdentityStaysInMemoryForTheSessionOnly() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = QuotaProvider(
            id: id, displayName: "Browser", accountURL: url, connection: .browserLogin,
            reset: .automaticOnly
        ) { _ in snapshot }
        let login = AccountBrowserLogin(key: "synthetic-key", account: identity)
        let vault = AccountMemoryVault()
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault, browserLogin: login)
        try await store.connect(id)
        #expect(store.states[id]?.account == identity)
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("account.") })

        let relaunched = UsageStore(providers: [provider], defaults: defaults, vault: vault, browserLogin: login)
        #expect(relaunched.states[id]?.connected == true)
        #expect(relaunched.states[id]?.account == nil)

        try await store.disconnect(id)
        #expect(store.states[id]?.account == nil)
    }

    @Test func existingConnectionLoadsIdentityOnFirstSuccessfulRefreshOnly() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        let reads = AccountReadCounter()
        let provider = makeProvider { _ in
            await reads.record()
            return identity
        }
        let vault = AccountMemoryVault()
        try vault.store("stored-synthetic-secret", for: id)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        await store.refresh(id)
        await waitForAccountRead(store)
        #expect(store.states[id]?.account == identity)
        #expect(store.states[id]?.loading == false)
        await store.refresh(id)
        await store.refresh(id)
        #expect(store.states[id]?.account == identity)
        #expect(await reads.count == 1)
        #expect(vault.interactions == [false, false, false])
    }

    @Test func failedCredentialReadDoesNotConsumeIdentityAttempt() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        let reads = AccountReadCounter()
        let provider = makeProvider { _ in
            await reads.record()
            return identity
        }
        let vault = AccountMemoryVault()
        try vault.store("stored-synthetic-secret", for: id)
        vault.failReads(with: VaultError.inaccessible)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        await store.refresh(id)
        #expect(await reads.count == 0)
        #expect(store.states[id]?.account == nil)
        #expect(store.states[id]?.message == VaultError.inaccessible.localizedDescription)
        vault.clearReadError()
        await store.refresh(id, interactive: true)
        await waitForAccountRead(store)
        #expect(await reads.count == 1)
        #expect(store.states[id]?.account == identity)
        #expect(store.states[id]?.message == nil)
        #expect(vault.interactions == [false, true])
    }

    @Test func failedIdentityReadIsNotRepeatedDuringLaunch() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        let reads = AccountReadCounter()
        let provider = makeProvider { _ in
            await reads.record()
            return nil
        }
        let vault = AccountMemoryVault()
        try vault.store("stored-synthetic-secret", for: id)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        await store.refresh(id)
        await waitForAccountRead(store)
        await store.refresh(id)
        #expect(await reads.count == 1)
        #expect(store.states[id]?.account == nil)
        #expect(store.states[id]?.snapshot == snapshot)
        #expect(store.states[id]?.message == nil)
        #expect(store.states[id]?.needsAuthentication == false)
        #expect(store.states[id]?.loading == false)
    }

    @Test func refreshReturnsWithFinalQuotaStateWhileIdentityReadIsBlocked() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = AsyncStream.makeStream(of: Void.self)
        let provider = makeProvider { _ in
            started.continuation.finish()
            for await _ in gate.stream { break }
            return identity
        }
        let vault = AccountMemoryVault()
        try vault.store("stored-synthetic-secret", for: id)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        await store.refresh(id)
        for await _ in started.stream { }
        #expect(store.states[id]?.snapshot == snapshot)
        #expect(defaults.data(forKey: "snapshot.\(id.rawValue)") != nil)
        #expect(store.states[id]?.message == nil)
        #expect(store.states[id]?.needsAuthentication == false)
        #expect(store.states[id]?.loading == false)
        #expect(store.states[id]?.account == nil)
        let accountTask = store.accountReadTask(for: id)
        gate.continuation.finish()
        await accountTask?.value
        #expect(store.states[id]?.account == identity)
    }

    @Test func disconnectIgnoresIdentityReadStartedByRefresh() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = AsyncStream.makeStream(of: Void.self)
        let provider = makeProvider { _ in
            started.continuation.finish()
            for await _ in gate.stream { break }
            return identity
        }
        let vault = AccountMemoryVault()
        try vault.store("stored-synthetic-secret", for: id)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        await store.refresh(id)
        for await _ in started.stream { }
        let accountTask = store.accountReadTask(for: id)
        try await store.disconnect(id)
        gate.continuation.finish()
        await accountTask?.value
        #expect(store.states[id]?.connected == false)
        #expect(store.states[id]?.account == nil)
    }

    @Test(arguments: [false, true])
    func unsuccessfulReconnectKeepsPendingIdentity(cancelled: Bool) async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = AsyncStream.makeStream(of: Void.self)
        let provider = QuotaProvider(
            id: id, displayName: "Identity", accountURL: url, connection: .apiKey,
            reset: .automaticOnly,
            readAccount: { _ in
                for await _ in gate.stream { break }
                return identity
            }
        ) { access in
            if case .apiKey("replacement") = access {
                if cancelled { throw CancellationError() }
                throw QuotaError.unavailable
            }
            return snapshot
        }
        let store = UsageStore(providers: [provider], defaults: defaults, vault: AccountMemoryVault())
        try await store.connect(id, secret: "original")
        let task = try #require(store.accountReadTask(for: id))
        if cancelled {
            await #expect(throws: CancellationError.self) { try await store.connect(id, secret: "replacement") }
        } else {
            await #expect(throws: QuotaError.self) { try await store.connect(id, secret: "replacement") }
        }
        gate.continuation.finish()
        await task.value
        #expect(!task.isCancelled)
        #expect(store.states[id]?.account == identity)
    }

    @Test func successfulReconnectCancelsIdentityStartedDuringVerification() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        let verificationStarted = AsyncStream.makeStream(of: Void.self)
        let verificationGate = AsyncStream.makeStream(of: Void.self)
        let identityGate = AsyncStream.makeStream(of: Void.self)
        let replacementIdentity = AccountIdentity(name: "Replacement")
        let provider = QuotaProvider(
            id: id, displayName: "Identity", accountURL: url, connection: .apiKey,
            reset: .automaticOnly,
            readAccount: { access in
                if case .apiKey("replacement") = access { return replacementIdentity }
                for await _ in identityGate.stream { break }
                return identity
            }
        ) { access in
            if case .apiKey("replacement") = access {
                verificationStarted.continuation.finish()
                for await _ in verificationGate.stream { break }
            }
            return snapshot
        }
        let vault = AccountMemoryVault()
        try vault.store("original", for: id)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        let reconnect = Task {
            defer { verificationStarted.continuation.finish() }
            try await store.connect(id, secret: "replacement")
        }
        for await _ in verificationStarted.stream { }
        await store.refresh(id)
        let oldTask = store.accountReadTask(for: id)
        verificationGate.continuation.finish()
        try await reconnect.value
        #expect(oldTask?.isCancelled == true)
        identityGate.continuation.finish()
        await oldTask?.value
        await waitForAccountRead(store)
        #expect(store.states[id]?.account == replacementIdentity)
    }

    @Test func failedDisconnectKeepsPendingIdentity() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = AsyncStream.makeStream(of: Void.self)
        let provider = makeProvider { _ in
            for await _ in gate.stream { break }
            return identity
        }
        let vault = AccountMemoryVault(removeError: VaultError.inaccessible)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        try await store.connect(id, secret: "original")
        let task = try #require(store.accountReadTask(for: id))
        await #expect(throws: VaultError.self) { try await store.disconnect(id) }
        gate.continuation.finish()
        await task.value
        #expect(!task.isCancelled)
        #expect(store.states[id]?.connected == true)
        #expect(store.states[id]?.account == identity)
    }

    @Test func connectReturnsWhileIdentityReadIsBlockedAndDisconnectIgnoresIt() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = AsyncStream.makeStream(of: Void.self)
        let provider = makeProvider { _ in
            started.continuation.finish()
            for await _ in gate.stream { break }
            return identity
        }
        let store = UsageStore(providers: [provider], defaults: defaults, vault: AccountMemoryVault())
        try await store.connect(id, secret: "synthetic-secret")
        #expect(store.states[id]?.connected == true)
        #expect(store.states[id]?.account == nil)
        for await _ in started.stream { }
        let accountTask = store.accountReadTask(for: id)
        try await store.disconnect(id)
        gate.continuation.finish()
        await accountTask?.value
        #expect(store.states[id]?.connected == false)
        #expect(store.states[id]?.account == nil)
        #expect(defaults.data(forKey: "account.\(id.rawValue)") == nil)
    }

    @Test func disconnectDuringQuotaReadPreventsIdentityStart() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        let reads = AccountReadCounter()
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = AsyncStream.makeStream(of: Void.self)
        let provider = QuotaProvider(
            id: id, displayName: "Identity", accountURL: url, connection: .apiKey,
            reset: .automaticOnly,
            readAccount: { _ in
                await reads.record()
                return identity
            }
        ) { _ in
            started.continuation.finish()
            for await _ in gate.stream { break }
            return snapshot
        }
        let vault = AccountMemoryVault()
        try vault.store("stored-synthetic-secret", for: id)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        let refresh = Task { await store.refresh(id) }
        for await _ in started.stream { }
        try await store.disconnect(id)
        gate.continuation.finish()
        await refresh.value
        #expect(await reads.count == 0)
        #expect(store.accountReadTask(for: id) == nil)
    }

    private func waitForAccountRead(_ store: UsageStore) async {
        await store.accountReadTask(for: id)?.value
    }

    private func makeProvider(
        readAccount: @escaping @Sendable (ProviderAccess) async -> AccountIdentity?
    ) -> QuotaProvider {
        QuotaProvider(
            id: id, displayName: "Identity", accountURL: url, connection: .apiKey,
            reset: .automaticOnly, readAccount: readAccount
        ) { _ in snapshot }
    }

    private func preferences() -> (UserDefaults, String) {
        let suite = "AccountIdentityStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private actor AccountReadCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@MainActor
private final class AccountBrowserLogin: ZaiBrowserLoginDriving {
    let key: String
    var account: AccountIdentity?
    init(key: String, account: AccountIdentity?) {
        self.key = key
        self.account = account
    }
    func login(_ id: ProviderID) async throws -> (key: String, account: AccountIdentity?) { (key, account) }
}

private final class AccountMemoryVault: CredentialVaulting, @unchecked Sendable {
    private let removeError: (any Error)?
    private let lock = NSLock()
    private var values: [ProviderID: String] = [:]
    private var readError: (any Error)?
    private(set) var interactions: [Bool] = []
    init(removeError: (any Error)? = nil) {
        self.removeError = removeError
    }
    func store(_ value: String, for id: ProviderID) throws {
        lock.lock()
        values[id] = value
        lock.unlock()
    }
    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        try withLock {
            interactions.append(interactive)
            if let readError { throw readError }
            guard let value = values[id] else { throw QuotaError.notConfigured }
            return value
        }
    }
    func failReads(with error: any Error) {
        withLock { readError = error }
    }
    func clearReadError() {
        withLock { readError = nil }
    }
    func remove(_ id: ProviderID) throws {
        if let removeError { throw removeError }
        lock.lock()
        values[id] = nil
        lock.unlock()
    }
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
