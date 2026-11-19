import Foundation
import Testing
import QuotaCore
@testable import AIUsage

@MainActor
struct ProviderLifecycleTests {
    private let id = ProviderID(rawValue: "additional-test-provider")
    private let account = URL(string: "https://example.invalid/account")!

    @Test func additionalProviderKeepsLastGoodObservationAcrossErrorsAndRestart() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 53, resetAt: nil)], observedAt: .now)
        let source = ChangingSource(snapshot)
        let provider = QuotaProvider(id: id, displayName: "Additional", accountURL: account,
                                     connection: .apiKey, reset: .automaticOnly) { _ in try await source.read() }
        let vault = RecordingCredentialVault()
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        try await store.connect(id, secret: "secret")
        #expect(store.states[id]?.snapshot == snapshot)
        await source.fail(with: .unavailable)
        await store.refresh(id)
        #expect(store.states[id]?.message != nil)
        #expect(store.states[id]?.snapshot == snapshot)
        let restored = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        #expect(restored.states[id]?.snapshot == snapshot)
        #expect(restored.states[id]?.message != nil)
        try await restored.disconnect(id)
        #expect(UsageStore(providers: [provider], defaults: defaults).states[id]?.snapshot == nil)
    }

    @Test func rejectedReplacementKeepsLastVerifiedQuota() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let reading = QuotaSnapshot(windows: [.init(id: "week", title: "Week", remainingPercent: 37, resetAt: nil)], observedAt: .now)
        let provider = QuotaProvider(id: id, displayName: "Plan", accountURL: account, connection: .apiKey, reset: .automaticOnly) { _ in
            throw QuotaError.unauthorized
        }
        let empty = UsageStore(providers: [provider], defaults: defaults)
        await #expect(throws: QuotaError.unauthorized) { try await empty.connect(id, secret: "rejected") }
        #expect(empty.states[id]?.connected == false)
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        defaults.set(try JSONEncoder().encode(reading), forKey: "snapshot.\(id.rawValue)")
        let store = UsageStore(providers: [provider], defaults: defaults)
        await #expect(throws: QuotaError.unauthorized) { try await store.connect(id, secret: "rejected") }
        #expect(store.states[id]?.snapshot == reading)
        #expect(UsageStore(providers: [provider], defaults: defaults).states[id]?.snapshot == reading)
    }

    @Test func disconnectDiscardsAnOutstandingRead() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = AsyncStream.makeStream(of: Void.self)
        let provider = QuotaProvider(id: id, displayName: "Additional", accountURL: account,
                                     connection: .apiKey, reset: .automaticOnly) { _ in
            started.continuation.finish()
            for await _ in gate.stream { break }
            return QuotaSnapshot(windows: [.init(id: "day", title: "Daily", remainingPercent: 45, resetAt: nil)], observedAt: .now)
        }
        let store = UsageStore(providers: [provider], defaults: defaults, vault: RecordingCredentialVault())
        let read = Task { try await store.connect(id, secret: "secret") }
        for await _ in started.stream { }
        try await store.disconnect(id)
        gate.continuation.finish()
        await #expect(throws: QuotaError.unavailable) { try await read.value }
        #expect(store.states[id]?.connected == false)
        #expect(store.states[id]?.snapshot == nil)
    }

    @Test func unknownRedemptionCannotSpendAnotherCreditOrRetryAutomatically() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let attempts = ResetAttempts()
        let provider = QuotaProvider(id: id, displayName: "Additional", accountURL: account,
                                     connection: .apiKey, reset: .banked(website: account) { _, credit, key in
            await attempts.record(credit, key)
            throw QuotaError.unavailable
        }) { _ in
            QuotaSnapshot(windows: [.init(id: "week", title: "Weekly", remainingPercent: 10, resetAt: nil)], observedAt: .now,
                          resetCredits: .init(availableCount: 1, nextID: "earned-1", nextTitle: nil, nextExpiry: nil))
        }
        let store = UsageStore(providers: [provider], defaults: defaults, vault: RecordingCredentialVault())
        try await store.connect(id, secret: "secret")
        await #expect(throws: ActionError.self) { try await store.redeemReset(id, creditID: "different") }
        #expect(await attempts.credits.isEmpty)
        await #expect(throws: ActionError.self) { try await store.redeemReset(id, creditID: "earned-1") }
        await #expect(throws: ActionError.self) { try await store.redeemReset(id, creditID: "earned-1") }
        #expect(await attempts.credits == ["earned-1"])
        await store.refresh(id)
        #expect(await attempts.credits == ["earned-1"])
        await #expect(throws: ActionError.self) { try await store.redeemReset(id, creditID: "earned-1") }
        let keys = await attempts.keys
        #expect(keys.count == 2 && keys[0] == keys[1])
    }

    @Test func refreshUsesKeychainInteractionOnlyWhenRequested() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 53, resetAt: nil)], observedAt: .now)
        let provider = QuotaProvider(id: id, displayName: "Plan", accountURL: account, connection: .apiKey, reset: .automaticOnly) { _ in snapshot }
        let vault = RecordingCredentialVault()
        try await UsageStore(providers: [provider], defaults: defaults, vault: vault).connect(id, secret: "secret")

        await UsageStore(providers: [provider], defaults: defaults, vault: vault).refresh(id)
        #expect(vault.readInteractions == [false])

        await UsageStore(providers: [provider], defaults: defaults, vault: vault).refresh(id, interactive: true)
        #expect(vault.readInteractions == [false, true])
    }

    @Test func redeemResetAllowsKeychainInteractionOnFirstUse() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(
            windows: [.init(id: "week", title: "Weekly", remainingPercent: 0, resetAt: nil)],
            observedAt: .now,
            resetCredits: ResetCredits(availableCount: 1, nextID: "credit", nextTitle: "Weekly reset", nextExpiry: nil)
        )
        let provider = QuotaProvider(
            id: id,
            displayName: "Plan",
            accountURL: account,
            connection: .apiKey,
            reset: .banked(website: account) { _, _, _ in .reset }
        ) { _ in snapshot }
        let vault = RecordingCredentialVault()
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        try await store.connect(id, secret: "secret")

        let result = try await store.redeemReset(id, creditID: "credit")

        #expect(result == "The provider confirmed the reset.")
        #expect(vault.readInteractions == [true])
    }

    @Test func failedAutomaticKeychainReadKeepsLastGoodQuota() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 53, resetAt: nil)], observedAt: .now)
        let provider = QuotaProvider(id: id, displayName: "Plan", accountURL: account, connection: .apiKey, reset: .automaticOnly) { _ in snapshot }
        let vault = RecordingCredentialVault()
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        try await store.connect(id, secret: "secret")
        vault.failReads(with: VaultError.inaccessible)

        await store.refresh(id)

        #expect(vault.readInteractions == [false])
        #expect(store.states[id]?.snapshot == snapshot)
        #expect(store.states[id]?.message == VaultError.inaccessible.localizedDescription)
        #expect(store.states[id]?.message?.contains("secret") == false)
    }

    @Test func menuListsOnlyConnectedProvidersThatNeedNoSignIn() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        func provider(_ raw: String, _ connection: ProviderConnection) -> QuotaProvider {
            QuotaProvider(id: ProviderID(rawValue: raw), displayName: raw, accountURL: account,
                          connection: connection, reset: .automaticOnly) { _ in throw QuotaError.unavailable }
        }
        let active = provider("active", .apiKey)
        // An OAuth connection without the current OAuth version needs a new sign-in.
        let signIn = provider("sign-in", .oauth)
        let disconnected = provider("disconnected", .apiKey)
        defaults.set(true, forKey: "connected.active")
        defaults.set(true, forKey: "connected.sign-in")
        let store = UsageStore(providers: [active, signIn, disconnected], defaults: defaults, vault: RecordingCredentialVault())
        #expect(store.states[signIn.id]?.needsAuthentication == true)
        #expect(store.activeProviders.map(\.id) == [active.id])
        #expect(store.needsSignIn)
    }

    @Test func restoredBrowserLoginWithoutCredentialNeedsSignIn() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "week", title: "Weekly", remainingPercent: 60, resetAt: nil)], observedAt: .now)
        let provider = QuotaProvider(id: id, displayName: "Browser", accountURL: account,
                                     connection: .browserLogin, reset: .automaticOnly) { _ in snapshot }
        defaults.set(true, forKey: "connected.\(id.rawValue)")
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "snapshot.\(id.rawValue)")
        let store = UsageStore(providers: [provider], defaults: defaults, vault: RecordingCredentialVault())
        #expect(store.activeProviders.map(\.id) == [id])
        await store.refresh(id)
        #expect(store.activeProviders.isEmpty)
        #expect(store.needsSignIn)
        #expect(store.states[id]?.message == QuotaError.notConfigured.localizedDescription)
    }

    @Test func automaticReadsWaitForTheRefreshIntervalAfterEveryReadStart() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let source = ChangingSource(QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 53, resetAt: nil)], observedAt: clock.now))
        // Each read of the limited provider takes 20 seconds, so a timestamp taken after the read is detected.
        let limited = QuotaProvider(id: id, displayName: "Limited", accountURL: account, connection: .apiKey,
                                    reset: .automaticOnly, refreshInterval: 180) { _ in
            await MainActor.run { clock.now += 20 }
            return try await source.read()
        }
        let plain = QuotaProvider(id: ProviderID(rawValue: "plain-test-provider"), displayName: "Plain", accountURL: account,
                                  connection: .apiKey, reset: .automaticOnly) { _ in try await source.read() }
        let vault = RecordingCredentialVault()
        let store = UsageStore(providers: [limited, plain], defaults: defaults, vault: vault, now: { clock.now })
        #expect(!store.quotaReadDue(limited, at: clock.now))

        var start = clock.now
        try await store.connect(limited.id, secret: "secret")
        try await store.connect(plain.id, secret: "secret")
        #expect(!store.quotaReadDue(limited, at: start.addingTimeInterval(179)))
        #expect(store.quotaReadDue(limited, at: start.addingTimeInterval(180)))
        #expect(!store.quotaReadDue(plain, at: clock.now.addingTimeInterval(59)))
        #expect(store.quotaReadDue(plain, at: clock.now.addingTimeInterval(60)))

        clock.now += 100
        start = clock.now
        await source.fail(with: .rateLimited)
        await #expect(throws: QuotaError.rateLimited) { try await store.connect(limited.id, secret: "secret") }
        #expect(!store.quotaReadDue(limited, at: start.addingTimeInterval(179)))
        #expect(store.quotaReadDue(limited, at: start.addingTimeInterval(180)))

        clock.now += 100
        start = clock.now
        await store.refresh(limited.id, interactive: true)
        #expect(store.states[limited.id]?.message == QuotaError.rateLimited.localizedDescription)
        #expect(!store.quotaReadDue(limited, at: start.addingTimeInterval(179)))
        #expect(store.quotaReadDue(limited, at: start.addingTimeInterval(180)))

        let restarted = UsageStore(providers: [limited, plain], defaults: defaults, vault: vault, now: { clock.now })
        #expect(restarted.quotaReadDue(limited, at: clock.now))
        #expect(restarted.quotaReadDue(plain, at: clock.now))
        try await store.disconnect(plain.id)
        #expect(!store.quotaReadDue(plain, at: clock.now.addingTimeInterval(3600)))
    }

    @Test func readRetriedAfterRenewalStartsTheRefreshInterval() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let source = ChangingSource(QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 53, resetAt: nil)], observedAt: clock.now))
        let provider = QuotaProvider(id: id, displayName: "Limited", accountURL: account, connection: .oauth,
                                     reset: .automaticOnly, refreshInterval: 180) { _ in try await source.read() }
        let driver = StubOAuthDriver(
            loginTokens: OAuthTokens(accessToken: "rejected", refreshToken: "refresh", expiresAt: clock.now.addingTimeInterval(3600)),
            refreshedTokens: OAuthTokens(accessToken: "renewed", refreshToken: "next", expiresAt: clock.now.addingTimeInterval(7200))
        )
        let store = UsageStore(providers: [provider], defaults: defaults, vault: MemoryCredentialVault(), oauth: driver, now: { clock.now })
        try await store.connect(id)

        clock.now += 100
        await source.fail(with: .unauthorized)
        // The renewal takes 20 seconds; the retried read starts after it.
        driver.beforeRefresh = {
            clock.now += 20
            await source.fail(with: nil)
        }
        await store.refresh(id)
        #expect(driver.refreshCalls == 1)
        #expect(store.states[id]?.message == nil)
        #expect(!store.quotaReadDue(provider, at: clock.now.addingTimeInterval(179)))
        #expect(store.quotaReadDue(provider, at: clock.now.addingTimeInterval(180)))
    }

    private func preferences() -> (UserDefaults, String) {
        let suite = "AIUsage.Tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private final class RecordingCredentialVault: CredentialVaulting, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderID: String] = [:]
    private var interactions: [Bool] = []
    private var readError: (any Error)?

    var readInteractions: [Bool] {
        withLock { interactions }
    }

    func store(_ value: String, for id: ProviderID) throws {
        withLock { values[id] = value }
    }

    func read(_ id: ProviderID, interactive: Bool) async throws -> String {
        try withLock {
            interactions.append(interactive)
            if let readError { throw readError }
            guard let value = values[id] else { throw QuotaError.notConfigured }
            return value
        }
    }

    func remove(_ id: ProviderID) throws {
        withLock { values[id] = nil }
    }

    func failReads(with error: any Error) {
        withLock { readError = error }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private actor ChangingSource {
    let snapshot: QuotaSnapshot
    var failure: QuotaError?
    init(_ snapshot: QuotaSnapshot) { self.snapshot = snapshot }
    func read() throws -> QuotaSnapshot {
        if let failure { throw failure }
        return snapshot
    }
    func fail(with error: QuotaError?) { failure = error }
}

private actor ResetAttempts {
    var credits: [String] = []
    var keys: [String] = []
    func record(_ credit: String, _ key: String) { credits.append(credit); keys.append(key) }
}
