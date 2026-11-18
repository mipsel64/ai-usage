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
        #expect(store.states[id]?.connected == true)
        #expect(store.states[id]?.snapshot == snapshot)
        #expect(store.states[id]?.account == nil)
        #expect(store.states[id]?.message == nil)
        #expect(store.states[id]?.needsAuthentication == false)
    }

    @Test func browserIdentityIsRestoredReplacedAndRemoved() async throws {
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
        #expect(defaults.data(forKey: "account.\(id.rawValue)") != nil)

        let restored = UsageStore(providers: [provider], defaults: defaults, vault: vault, browserLogin: login)
        #expect(restored.states[id]?.account == identity)
        login.account = nil
        try await restored.connect(id)
        #expect(restored.states[id]?.account == nil)
        #expect(defaults.data(forKey: "account.\(id.rawValue)") == nil)

        login.account = identity
        try await restored.connect(id)
        try await restored.disconnect(id)
        #expect(defaults.data(forKey: "account.\(id.rawValue)") == nil)
        #expect(restored.states[id]?.account == nil)
        let afterDisconnect = UsageStore(providers: [provider], defaults: defaults, vault: vault, browserLogin: login)
        #expect(afterDisconnect.states[id]?.account == nil)
    }

    @Test func existingConnectionLoadsIdentityOnlyOncePerLaunch() async throws {
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
        await store.loadAccounts()
        await store.loadAccounts()
        #expect(store.states[id]?.account == identity)
        #expect(await reads.count == 1)
        #expect(vault.interactions == [false])
    }

    @Test func disconnectIgnoresAnOutstandingIdentityRead() async throws {
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
        let connection = Task { try await store.connect(id, secret: "synthetic-secret") }
        for await _ in started.stream { }
        try await store.disconnect(id)
        gate.continuation.finish()
        try await connection.value
        #expect(store.states[id]?.connected == false)
        #expect(store.states[id]?.account == nil)
        #expect(defaults.data(forKey: "account.\(id.rawValue)") == nil)
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
    private let lock = NSLock()
    private var values: [ProviderID: String] = [:]
    private(set) var interactions: [Bool] = []
    func store(_ value: String, for id: ProviderID) throws {
        lock.lock()
        values[id] = value
        lock.unlock()
    }
    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        try withLock {
            interactions.append(interactive)
            guard let value = values[id] else { throw QuotaError.notConfigured }
            return value
        }
    }
    func remove(_ id: ProviderID) throws {
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
