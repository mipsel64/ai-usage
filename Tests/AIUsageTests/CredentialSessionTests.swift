import Foundation
import Testing
import QuotaCore
@testable import AIUsage

@MainActor
struct CredentialSessionTests {
    private let id = ProviderID(rawValue: "credential-session-test")
    private let account = URL(string: "https://example.invalid/account")!
    private let snapshot = QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 70, resetAt: nil)], observedAt: .now)

    @Test func renewalStartsAtTheLeadTimeAndNotEarlier() async throws {
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(OAuthTokens.refreshLeadTime + 1))
        let renewed = tokens("renewed", expiresAt: clock.now.addingTimeInterval(7200))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: renewed)
        let session = try session(initial, driver: driver, clock: clock)

        #expect(try await session.access(for: provider(), interactive: false).oauthTokens() == initial)
        #expect(driver.refreshCalls == 0)
        clock.now = clock.now.addingTimeInterval(1)
        #expect(try await session.access(for: provider(), interactive: false).oauthTokens() == renewed)
        #expect(driver.refreshCalls == 1)
    }

    @Test func concurrentCallersShareOneRenewal() async throws {
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(60))
        let renewed = tokens("renewed", expiresAt: clock.now.addingTimeInterval(7200))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: renewed)
        let session = try session(initial, driver: driver, clock: clock)
        let (started, release) = hold(driver)

        let first = Task { try await session.access(for: provider(), interactive: false).oauthTokens() }
        for await _ in started {}
        let second = Task { try await session.access(for: provider(), interactive: false).oauthTokens() }
        for _ in 0..<10 { await Task.yield() }
        release.finish()

        #expect(try await first.value == renewed)
        #expect(try await second.value == renewed)
        #expect(driver.refreshCalls == 1)
    }

    @Test func tenPollsReadTheVaultOnce() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = tokens("initial", expiresAt: Date().addingTimeInterval(3600))
        let vault = MemoryCredentialVault()
        let store = UsageStore(
            providers: [provider()], defaults: defaults, vault: vault,
            oauth: StubOAuthDriver(loginTokens: initial, refreshedTokens: initial)
        )
        try await store.connect(id)

        for _ in 0..<10 { await store.refresh(id) }

        #expect(vault.reads == 1)
        #expect(store.states[id]?.message == nil)
    }

    @Test func failedStoreKeepsRenewedTokensAndRetriesTheStore() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let renewed = tokens("renewed", expiresAt: clock.now.addingTimeInterval(10_800))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: renewed)
        let vault = MemoryCredentialVault()
        let store = UsageStore(providers: [provider()], defaults: defaults, vault: vault, oauth: driver, now: { clock.now })
        try await store.connect(id)
        vault.failStores(with: VaultError.inaccessible)
        clock.now = clock.now.addingTimeInterval(3600 - 60)

        await store.refresh(id)
        #expect(driver.refreshCalls == 1)
        #expect(store.states[id]?.needsAuthentication == false)
        #expect(store.states[id]?.message == UsageStore.unsavedSignIn)

        let attempts = vault.storeAttempts
        await store.refresh(id)
        #expect(driver.refreshCalls == 1)
        #expect(vault.storeAttempts == attempts + 1)
        #expect(store.states[id]?.message == UsageStore.unsavedSignIn)

        vault.failStores(with: nil)
        await store.refresh(id)
        #expect(driver.refreshCalls == 1)
        #expect(vault.storedTokens(id) == renewed)
        #expect(store.states[id]?.message == nil)
    }

    @Test func refusedRenewalStopsAutomaticPollsUntilManualRefreshOrSignIn() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: initial)
        driver.refreshError = OAuthError.unauthorized
        let reads = QuotaReadCounter()
        let provider = provider { try await reads.record() }
        let store = UsageStore(providers: [provider], defaults: defaults, vault: MemoryCredentialVault(), oauth: driver, now: { clock.now })
        try await store.connect(id)
        clock.now = clock.now.addingTimeInterval(3600 - 60)

        await store.refresh(id)
        #expect(driver.refreshCalls == 1)
        #expect(store.states[id]?.needsAuthentication == true)
        let readsAfterRefusal = await reads.count
        await store.refresh(id)
        await store.refresh(id)
        #expect(driver.refreshCalls == 1)
        #expect(await reads.count == readsAfterRefusal)

        await store.refresh(id, interactive: true)
        #expect(driver.refreshCalls == 2)

        driver.refreshError = nil
        driver.loginTokens = tokens("signed-in", expiresAt: clock.now.addingTimeInterval(3600))
        try await store.connect(id)
        #expect(store.states[id]?.needsAuthentication == false)
        await store.refresh(id)
        #expect(driver.refreshCalls == 2)
        #expect(store.states[id]?.needsAuthentication == false)
        #expect(store.states[id]?.message == nil)
    }

    @Test func temporaryRenewalFailureStillReadsWithAValidTokenAndRetries() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let renewed = tokens("renewed", expiresAt: clock.now.addingTimeInterval(10_800))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: renewed)
        driver.refreshError = OAuthError.unavailable
        let vault = MemoryCredentialVault()
        let reads = QuotaReadCounter()
        let store = UsageStore(
            providers: [provider { try await reads.record() }], defaults: defaults, vault: vault, oauth: driver, now: { clock.now }
        )
        try await store.connect(id)
        clock.now = clock.now.addingTimeInterval(3600 - 240)

        await store.refresh(id)
        #expect(driver.refreshCalls == 1)
        #expect(await reads.count == 2)
        #expect(store.states[id]?.needsAuthentication == false)
        #expect(store.states[id]?.message == nil)
        await store.refresh(id)
        #expect(driver.refreshCalls == 2)

        driver.refreshError = nil
        await store.refresh(id)
        #expect(driver.refreshCalls == 3)
        #expect(driver.refreshedFrom.allSatisfy { $0 == initial })
        #expect(vault.storedTokens(id) == renewed)
    }

    @Test func temporaryRenewalFailureWithExpiredTokensReadsNothing() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: initial)
        driver.refreshError = OAuthError.unavailable
        let reads = QuotaReadCounter()
        let store = UsageStore(
            providers: [provider { try await reads.record() }], defaults: defaults, vault: MemoryCredentialVault(),
            oauth: driver, now: { clock.now }
        )
        try await store.connect(id)
        clock.now = clock.now.addingTimeInterval(3601)

        await store.refresh(id)
        #expect(driver.refreshCalls == 1)
        #expect(await reads.count == 1)
        #expect(store.states[id]?.needsAuthentication == false)
        #expect(store.states[id]?.message == CredentialSession.renewalFailure)
    }

    @Test func rejectedFreshTokensRenewAtMostOncePerLeadTime() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let renewed = tokens("renewed", expiresAt: clock.now.addingTimeInterval(10_800))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: renewed)
        let reads = QuotaReadCounter()
        let store = UsageStore(
            providers: [provider { try await reads.record() }], defaults: defaults, vault: MemoryCredentialVault(),
            oauth: driver, now: { clock.now }
        )
        try await store.connect(id)
        await reads.rejectReads()

        for _ in 0..<3 {
            await store.refresh(id)
            clock.now = clock.now.addingTimeInterval(60)
        }
        #expect(driver.refreshCalls == 1)

        clock.now = clock.now.addingTimeInterval(OAuthTokens.refreshLeadTime)
        await store.refresh(id)
        #expect(driver.refreshCalls == 2)

        await store.refresh(id, interactive: true)
        #expect(driver.refreshCalls == 3)
        #expect(store.states[id]?.needsAuthentication == true)
    }

    @Test func failedForcedRenewalsAlsoPauseForTheLeadTime() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: initial)
        driver.refreshError = OAuthError.unavailable
        let reads = QuotaReadCounter()
        let store = UsageStore(
            providers: [provider { try await reads.record() }], defaults: defaults, vault: MemoryCredentialVault(),
            oauth: driver, now: { clock.now }
        )
        try await store.connect(id)
        await reads.rejectReads()

        for _ in 0..<3 {
            await store.refresh(id)
            clock.now = clock.now.addingTimeInterval(60)
        }

        #expect(driver.refreshCalls == 1)
        #expect(store.states[id]?.needsAuthentication == true)
    }

    @Test func reconnectDuringAWriteDoesNotRepeatItWithTheNewConnection() async throws {
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let replacement = tokens("replacement", expiresAt: clock.now.addingTimeInterval(3600))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: initial)
        let session = try session(initial, driver: driver, clock: clock)
        let access = try await session.access(for: provider(), interactive: true)
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = AsyncStream.makeStream(of: Void.self)
        let writes = QuotaReadCounter()

        let write = Task {
            try await session.withRenewal(access, for: id) { (_: ProviderAccess) async throws -> Redemption in
                try await writes.record()
                started.continuation.finish()
                for await _ in gate.stream {}
                throw QuotaError.unauthorized
            }
        }
        for await _ in started.stream {}
        try session.connect(.oauth(replacement), for: id)
        #expect(try await session.access(for: provider(), interactive: false).oauthTokens() == replacement)
        gate.continuation.finish()

        await #expect(throws: QuotaError.unavailable) { try await write.value }
        #expect(await writes.count == 1)
        #expect(driver.refreshCalls == 0)
    }

    @Test func bankedResetRetriesTheWriteOnceWithTheSameKeyAfterARejectedToken() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = tokens("initial", expiresAt: Date().addingTimeInterval(3600))
        let renewed = tokens("renewed", expiresAt: Date().addingTimeInterval(10_800))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: renewed)
        let consumer = ResetConsumer([.failure(.unauthorized), .success(.reset)])
        let store = UsageStore(providers: [bankedProvider(consumer)], defaults: defaults, vault: MemoryCredentialVault(), oauth: driver)
        try await store.connect(id)

        #expect(try await store.redeemReset(id, creditID: "credit") == "The provider confirmed the reset.")

        let calls = await consumer.calls
        #expect(driver.refreshCalls == 1)
        #expect(calls.map(\.token) == [initial.accessToken, renewed.accessToken])
        #expect(calls.map(\.credit) == ["credit", "credit"])
        #expect(calls.count == 2 && calls[0].key == calls[1].key)
    }

    @Test func bankedResetWithAnUnknownResultIsNeitherRenewedNorRepeated() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = tokens("initial", expiresAt: Date().addingTimeInterval(3600))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: initial)
        let consumer = ResetConsumer([.failure(.unavailable), .success(.reset)])
        let store = UsageStore(providers: [bankedProvider(consumer)], defaults: defaults, vault: MemoryCredentialVault(), oauth: driver)
        try await store.connect(id)

        await #expect(throws: ActionError.self) { try await store.redeemReset(id, creditID: "credit") }

        #expect(await consumer.calls.count == 1)
        #expect(driver.refreshCalls == 0)
        #expect(store.states[id]?.message == "Reset result unknown. Check the provider’s usage page before trying again.")
    }

    @Test func renewalUsesNewerStoredTokensInsideTheLeadTime() async throws {
        let clock = OAuthClock(now: Date())
        let memory = tokens("memory", expiresAt: clock.now.addingTimeInterval(3600))
        let stored = tokens("other-instance", expiresAt: clock.now.addingTimeInterval(3700))
        let renewed = tokens("renewed", expiresAt: clock.now.addingTimeInterval(10_800))
        let driver = StubOAuthDriver(loginTokens: memory, refreshedTokens: renewed)
        let vault = MemoryCredentialVault()
        let session = try session(memory, driver: driver, clock: clock, vault: vault)
        #expect(try await session.access(for: provider(), interactive: false).oauthTokens() == memory)
        try vault.store(String(decoding: try JSONEncoder().encode(stored), as: UTF8.self), for: id)
        clock.now = clock.now.addingTimeInterval(3600 - 60)

        #expect(try await session.access(for: provider(), interactive: false).oauthTokens() == renewed)
        #expect(driver.refreshedFrom == [stored])
    }

    @Test func deletedCredentialStopsTheRenewal() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: tokens("renewed", expiresAt: clock.now.addingTimeInterval(10_800)))
        let vault = MemoryCredentialVault()
        let store = UsageStore(providers: [provider()], defaults: defaults, vault: vault, oauth: driver, now: { clock.now })
        try await store.connect(id)
        await store.refresh(id)
        try vault.remove(id)
        let attempts = vault.storeAttempts
        clock.now = clock.now.addingTimeInterval(3600 - 60)

        await store.refresh(id)
        await store.refresh(id)

        #expect(driver.refreshCalls == 0)
        #expect(vault.storeAttempts == attempts)
        #expect(vault.storedTokens(id) == nil)
        #expect(store.states[id]?.needsAuthentication == true)
    }

    @Test func cancelledCallerDoesNotLoseRenewedTokens() async throws {
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(60))
        let renewed = tokens("renewed", expiresAt: clock.now.addingTimeInterval(7200))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: renewed)
        let vault = MemoryCredentialVault()
        let session = try session(initial, driver: driver, clock: clock, vault: vault)
        let (started, release) = hold(driver)

        let caller = Task { try await session.access(for: provider(), interactive: false) }
        for await _ in started {}
        caller.cancel()
        release.finish()
        _ = await caller.result

        #expect(try await session.access(for: provider(), interactive: false).oauthTokens() == renewed)
        #expect(driver.refreshCalls == 1)
        #expect(vault.storedTokens(id) == renewed)
    }

    @Test func disconnectDuringRenewalStoresNothing() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let renewed = tokens("renewed", expiresAt: clock.now.addingTimeInterval(10_800))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: renewed)
        let vault = MemoryCredentialVault()
        let store = UsageStore(providers: [provider()], defaults: defaults, vault: vault, oauth: driver, now: { clock.now })
        try await store.connect(id)
        clock.now = clock.now.addingTimeInterval(3600 - 60)
        let (started, release) = hold(driver)

        let poll = Task { await store.refresh(id) }
        for await _ in started {}
        try await store.disconnect(id)
        let attempts = vault.storeAttempts
        release.finish()
        await poll.value

        #expect(vault.storeAttempts == attempts)
        #expect(vault.storedTokens(id) == nil)
        #expect(store.states[id]?.connected == false)
    }

    @Test func newerValidTokensInTheVaultReplaceANetworkRenewal() async throws {
        let clock = OAuthClock(now: Date())
        let initial = tokens("initial", expiresAt: clock.now.addingTimeInterval(3600))
        let newer = tokens("other-instance", expiresAt: clock.now.addingTimeInterval(10_800))
        let driver = StubOAuthDriver(loginTokens: initial, refreshedTokens: initial)
        let vault = MemoryCredentialVault()
        let session = try session(initial, driver: driver, clock: clock, vault: vault)
        #expect(try await session.access(for: provider(), interactive: false).oauthTokens() == initial)
        try vault.store(String(decoding: try JSONEncoder().encode(newer), as: UTF8.self), for: id)
        clock.now = clock.now.addingTimeInterval(3600 - 60)

        #expect(try await session.access(for: provider(), interactive: false).oauthTokens() == newer)
        #expect(driver.refreshCalls == 0)
    }

    private func tokens(_ name: String, expiresAt: Date) -> OAuthTokens {
        OAuthTokens(accessToken: "\(name)-access", refreshToken: "\(name)-refresh", expiresAt: expiresAt)
    }

    private func provider(onRead: @escaping @Sendable () async throws -> Void = {}) -> QuotaProvider {
        let snapshot = snapshot
        return QuotaProvider(id: id, displayName: "OAuth", accountURL: account, connection: .oauth, reset: .automaticOnly) { _ in
            try await onRead()
            return snapshot
        }
    }

    private func bankedProvider(_ consumer: ResetConsumer) -> QuotaProvider {
        let snapshot = QuotaSnapshot(
            windows: [.init(id: "week", title: "Weekly", remainingPercent: 0, resetAt: nil)],
            observedAt: .now,
            resetCredits: ResetCredits(availableCount: 1, nextID: "credit", nextTitle: "Weekly reset", nextExpiry: nil)
        )
        return QuotaProvider(
            id: id, displayName: "OAuth", accountURL: account, connection: .oauth,
            reset: .banked(website: account) { access, credit, key in try await consumer.consume(access, credit, key) }
        ) { _ in snapshot }
    }

    private func session(
        _ tokens: OAuthTokens,
        driver: StubOAuthDriver,
        clock: OAuthClock,
        vault: MemoryCredentialVault = MemoryCredentialVault()
    ) throws -> CredentialSession {
        let session = CredentialSession(vault: vault, oauth: driver, now: { clock.now })
        try session.connect(.oauth(tokens), for: id)
        return session
    }

    /// Suspends the next renewal: `started` ends when it begins, and `release.finish()` lets it complete.
    /// A renewal that runs in a cancelled caller's task fails, because the hold checks for cancellation.
    private func hold(_ driver: StubOAuthDriver) -> (started: AsyncStream<Void>, release: AsyncStream<Void>.Continuation) {
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = AsyncStream.makeStream(of: Void.self)
        driver.beforeRefresh = {
            started.continuation.finish()
            for await _ in gate.stream {}
            try Task.checkCancellation()
        }
        return (started.stream, gate.continuation)
    }

    private func preferences() -> (UserDefaults, String) {
        let suite = "CredentialSessionTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}

private actor QuotaReadCounter {
    private(set) var count = 0
    private var rejecting = false
    func record() throws {
        count += 1
        if rejecting { throw QuotaError.unauthorized }
    }
    func rejectReads() { rejecting = true }
}

private actor ResetConsumer {
    private var outcomes: [Result<Redemption, QuotaError>]
    private(set) var calls: [(token: String, credit: String, key: String)] = []
    init(_ outcomes: [Result<Redemption, QuotaError>]) { self.outcomes = outcomes }
    func consume(_ access: ProviderAccess, _ credit: String, _ key: String) throws -> Redemption {
        calls.append((try access.oauthTokens().accessToken, credit, key))
        return try outcomes.removeFirst().get()
    }
}
