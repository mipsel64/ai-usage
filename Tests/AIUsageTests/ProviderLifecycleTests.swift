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
        await source.goOffline()
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
        let store = UsageStore(providers: [provider], defaults: defaults, vault: vault)
        try await store.connect(id, secret: "secret")

        await store.refresh(id)
        #expect(vault.readInteractions == [false])

        await store.refresh(id, interactive: true)
        #expect(vault.readInteractions == [false, true])
    }

    @Test func redeemResetAllowsKeychainInteractionButRefreshesAutomatically() async throws {
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
        #expect(vault.readInteractions == [true, false])
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
    var offline = false
    init(_ snapshot: QuotaSnapshot) { self.snapshot = snapshot }
    func read() throws -> QuotaSnapshot {
        if offline { throw QuotaError.unavailable }
        return snapshot
    }
    func goOffline() { offline = true }
}

private actor ResetAttempts {
    var credits: [String] = []
    var keys: [String] = []
    func record(_ credit: String, _ key: String) { credits.append(credit); keys.append(key) }
}
