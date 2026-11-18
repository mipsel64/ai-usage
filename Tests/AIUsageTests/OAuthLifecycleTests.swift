import Foundation
import Testing
import QuotaCore
@testable import AIUsage

@MainActor
struct OAuthLifecycleTests {
    private let id = ProviderID(rawValue: "oauth-lifecycle-test")
    private let account = URL(string: "https://example.invalid/account")!

    @Test func legacyMonitoringConnectionRequiresOAuthReconnection() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        defaults.set(true, forKey: "desktopFeed.\(id.rawValue)")
        let provider = QuotaProvider(id: id, displayName: "OAuth", accountURL: account, connection: .oauth, reset: .automaticOnly) { _ in
            throw QuotaError.notConfigured
        }
        let tokens = OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))

        let store = UsageStore(
            providers: [provider],
            defaults: defaults,
            vault: MemoryCredentialVault(),
            oauth: StubOAuthDriver(loginTokens: tokens, refreshedTokens: tokens)
        )

        #expect(store.states[id]?.connected == true)
        #expect(store.states[id]?.needsAuthentication == true)

        await store.refresh(id)

        #expect(store.states[id]?.needsAuthentication == true)
        #expect(store.states[id]?.message == "Reconnect with OAuth to use direct OAuth.")
    }

    @Test func completedOAuthConnectionDoesNotRequireReconnectionOnRestart() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 80, resetAt: nil)], observedAt: .now)
        let provider = QuotaProvider(id: id, displayName: "OAuth", accountURL: account, connection: .oauth, reset: .automaticOnly) { _ in snapshot }
        let tokens = OAuthTokens(accessToken: "access", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))
        let vault = MemoryCredentialVault()
        let driver = StubOAuthDriver(loginTokens: tokens, refreshedTokens: tokens)
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault, oauth: driver)
        try await store.connect(id)

        let restored = UsageStore(providers: [provider], defaults: defaults, vault: vault, oauth: driver)

        #expect(restored.states[id]?.connected == true)
        #expect(restored.states[id]?.needsAuthentication == false)
        #expect(restored.states[id]?.snapshot == snapshot)
    }

    @Test func revokedRefreshKeepsLastQuotaAndRequestsSignIn() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 65, resetAt: nil)], observedAt: .now)
        let source = OAuthReadingSource(snapshot: snapshot)
        let provider = QuotaProvider(id: id, displayName: "OAuth", accountURL: account, connection: .oauth, reset: .automaticOnly) { _ in
            try await source.read()
        }
        let initial = OAuthTokens(accessToken: "initial", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: initial)
        driver.refreshError = OAuthError.unauthorized
        let store = UsageStore(providers: [provider], defaults: defaults, vault: MemoryCredentialVault(), oauth: driver)
        try await store.connect(id)
        #expect(store.states[id]?.snapshot == snapshot)

        await source.rejectReads()
        await store.refresh(id)

        #expect(driver.refreshCalls == 1)
        #expect(store.states[id]?.needsAuthentication == true)
        #expect(store.states[id]?.snapshot == snapshot)
        #expect(store.states[id]?.message == OAuthError.unauthorized.localizedDescription)
    }

    @Test func failedReconnectDoesNotReplaceStoredOAuthCredentials() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 65, resetAt: nil)], observedAt: .now)
        let source = OAuthReadingSource(snapshot: snapshot)
        let provider = QuotaProvider(id: id, displayName: "OAuth", accountURL: account, connection: .oauth, reset: .automaticOnly) { _ in
            try await source.read()
        }
        let initial = OAuthTokens(accessToken: "initial", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))
        let refreshed = OAuthTokens(accessToken: "replacement", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: refreshed)
        let vault = MemoryCredentialVault()
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault, oauth: driver)
        try await store.connect(id)
        let saved = try await vault.read(id, interactive: false)
        await source.rejectReads()

        await #expect(throws: QuotaError.unauthorized) {
            try await store.connect(id)
        }

        #expect(try await vault.read(id, interactive: false) == saved)
    }

    @Test func bankedResetRefreshesExpiredOAuthBeforeConsumingCredit() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(
            windows: [.init(id: "week", title: "Weekly", remainingPercent: 0, resetAt: nil)],
            observedAt: .now,
            resetCredits: ResetCredits(availableCount: 1, nextID: "credit", nextTitle: "Weekly reset", nextExpiry: Date().addingTimeInterval(3600))
        )
        let recorder = OAuthRedemptionRecorder()
        let provider = QuotaProvider(
            id: id,
            displayName: "OAuth",
            accountURL: account,
            connection: .oauth,
            reset: .banked(website: account) { access, _, _ in
                try await recorder.record(access)
                return .reset
            }
        ) { _ in snapshot }
        let initial = OAuthTokens(accessToken: "expired", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600))
        let refreshed = OAuthTokens(accessToken: "fresh", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(10_800))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: refreshed)
        let clock = OAuthClock(now: Date())
        let vault = MemoryCredentialVault()
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault, oauth: driver, now: { clock.now })
        try await store.connect(id)
        clock.now = Date().addingTimeInterval(7200)

        let result = try await store.redeemReset(id, creditID: "credit")

        #expect(result == "The provider confirmed the reset.")
        #expect(driver.refreshCalls == 1)
        #expect(await recorder.accessToken() == "fresh")
    }

    private func preferences() -> (UserDefaults, String) {
        let suite = "OAuthLifecycleTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private actor OAuthReadingSource {
    let snapshot: QuotaSnapshot
    var rejected = false
    init(snapshot: QuotaSnapshot) { self.snapshot = snapshot }
    func read() throws -> QuotaSnapshot {
        if rejected { throw QuotaError.unauthorized }
        return snapshot
    }
    func rejectReads() { rejected = true }
}

private actor OAuthRedemptionRecorder {
    var token: String?
    func record(_ access: ProviderAccess) throws {
        token = try access.oauthTokens().accessToken
    }
    func accessToken() -> String? { token }
}

@MainActor
private final class StubOAuthDriver: SubscriptionOAuthDriving {
    let loginTokens: OAuthTokens
    let refreshedTokens: OAuthTokens
    var refreshError: Error?
    var refreshCalls = 0

    init(loginTokens: OAuthTokens, refreshedTokens: OAuthTokens) {
        self.loginTokens = loginTokens
        self.refreshedTokens = refreshedTokens
    }

    func login(_ id: ProviderID) async throws -> OAuthTokens { loginTokens }

    func refresh(_ tokens: OAuthTokens, for id: ProviderID) async throws -> OAuthTokens {
        refreshCalls += 1
        if let refreshError { throw refreshError }
        return refreshedTokens
    }
}

@MainActor
private final class OAuthClock {
    var now: Date
    init(now: Date) { self.now = now }
}

private final class MemoryCredentialVault: CredentialVaulting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderID: String] = [:]

    func store(_ value: String, for id: ProviderID) throws {
        withLock { values[id] = value }
    }

    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        try withLock {
            guard let value = values[id] else { throw QuotaError.notConfigured }
            return value
        }
    }

    func remove(_ id: ProviderID) throws {
        withLock { values[id] = nil }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
