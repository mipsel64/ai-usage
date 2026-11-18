import Foundation
import Testing
import QuotaCore
@testable import AIUsage

@MainActor
struct BrowserLoginLifecycleTests {
    private let id = ProviderID(rawValue: "browser-login-lifecycle-test")
    private let account = URL(string: "https://example.invalid/account")!

    @Test func browserLoginVerifiesStoresAndDisconnectsMintedKey() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "week", title: "Weekly", remainingPercent: 62, resetAt: nil)], observedAt: .now)
        let source = BrowserLoginReadingSource(snapshot: snapshot)
        let provider = makeProvider { try await source.read($0) }
        let vault = BrowserLoginVault()
        let login = StubBrowserLogin(key: "minted-id.minted-secret")
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault, browserLogin: login)

        try await store.connect(id)
        #expect(login.loginCalls == 1)
        #expect(await source.keys == ["minted-id.minted-secret"])
        #expect(vault.values[id] == "minted-id.minted-secret")
        #expect(store.states[id]?.connected == true)
        #expect(store.states[id]?.snapshot == snapshot)

        let restored = UsageStore(providers: [provider], defaults: defaults, vault: vault, browserLogin: login)
        await restored.refresh(id)
        #expect(await source.keys == ["minted-id.minted-secret", "minted-id.minted-secret"])
        try await restored.disconnect(id)
        #expect(vault.values[id] == nil)
        #expect(restored.states[id]?.connected == false)
    }

    @Test func browserLoginDoesNotStoreUnverifiedKeyOrAcceptManualInputs() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = makeProvider { _ in throw QuotaError.unauthorized }
        let vault = BrowserLoginVault()
        let login = StubBrowserLogin(key: "unverified.secret")
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault, browserLogin: login)
        await #expect(throws: QuotaError.unauthorized) { try await store.connect(id) }
        #expect(vault.values[id] == nil)
        #expect(store.states[id]?.connected == false)
        await #expect(throws: QuotaError.notConfigured) { try await store.connect(id, secret: "manual-key") }
        await #expect(throws: QuotaError.notConfigured) { try await store.connect(id, executable: account) }
        await #expect(throws: QuotaError.notConfigured) { try await store.connect(id, desktopFeed: true) }
        #expect(login.loginCalls == 1)
    }

    private func makeProvider(read: @escaping @Sendable (ProviderAccess) async throws -> QuotaSnapshot) -> QuotaProvider {
        QuotaProvider(id: id, displayName: "Browser", accountURL: account, connection: .browserLogin, reset: .automaticOnly, read: read)
    }

    private func preferences() -> (UserDefaults, String) {
        let suite = "BrowserLoginLifecycleTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

@MainActor
private final class StubBrowserLogin: ZaiBrowserLoginDriving {
    let key: String
    private(set) var loginCalls = 0
    init(key: String) { self.key = key }
    func login(_ id: ProviderID) async throws -> String {
        loginCalls += 1
        return key
    }
}

private actor BrowserLoginReadingSource {
    let snapshot: QuotaSnapshot
    private(set) var keys: [String] = []
    init(snapshot: QuotaSnapshot) { self.snapshot = snapshot }
    func read(_ access: ProviderAccess) throws -> QuotaSnapshot {
        keys.append(try access.key())
        return snapshot
    }
}

private final class BrowserLoginVault: CredentialVaulting, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProviderID: String] = [:]
    var values: [ProviderID: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func store(_ value: String, for id: ProviderID) throws {
        lock.lock()
        storage[id] = value
        lock.unlock()
    }
    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        try withLock {
            guard let value = storage[id] else { throw QuotaError.notConfigured }
            return value
        }
    }
    func remove(_ id: ProviderID) throws {
        lock.lock()
        storage[id] = nil
        lock.unlock()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
