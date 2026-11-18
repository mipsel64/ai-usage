import Foundation
import Testing
import QuotaCore
@testable import AIUsage

@MainActor
struct ProviderLifecycleTests {
    private let id = ProviderID(rawValue: "additional-test-provider")
    private let account = URL(string: "https://example.invalid/account")!
    private let local = ProviderConnection.statusLine(toolName: "Additional", helperName: "capture")

    @Test func additionalProviderKeepsLastGoodObservationAcrossErrorsAndRestart() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = QuotaSnapshot(windows: [.init(id: "hour", title: "Hourly", remainingPercent: 53, resetAt: nil)], observedAt: .now)
        let source = ChangingSource(snapshot)
        let provider = QuotaProvider(id: id, displayName: "Additional", accountURL: account,
                                     connection: local, reset: .automaticOnly) { _ in try await source.read() }
        let store = UsageStore(providers: [provider], defaults: defaults)
        try await store.connect(id)
        #expect(store.states[id]?.snapshot == snapshot)
        await source.goOffline()
        await store.refresh(id)
        #expect(store.states[id]?.message != nil)
        #expect(store.states[id]?.snapshot == snapshot)
        let restored = UsageStore(providers: [provider], defaults: defaults)
        #expect(restored.states[id]?.snapshot == snapshot)
        #expect(restored.states[id]?.message != nil)
        try await restored.disconnect(id)
        #expect(UsageStore(providers: [provider], defaults: defaults).states[id]?.snapshot == nil)
    }

    @Test func disconnectDiscardsAnOutstandingRead() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = AsyncStream.makeStream(of: Void.self)
        let gate = AsyncStream.makeStream(of: Void.self)
        let provider = QuotaProvider(id: id, displayName: "Additional", accountURL: account,
                                     connection: local, reset: .automaticOnly) { _ in
            started.continuation.finish()
            for await _ in gate.stream { break }
            return QuotaSnapshot(windows: [.init(id: "day", title: "Daily", remainingPercent: 45, resetAt: nil)], observedAt: .now)
        }
        let store = UsageStore(providers: [provider], defaults: defaults)
        let read = Task { try await store.connect(id) }
        for await _ in started.stream { }
        try await store.disconnect(id)
        gate.continuation.finish()
        try await read.value
        #expect(store.states[id]?.connected == false)
        #expect(store.states[id]?.snapshot == nil)
    }

    @Test func unknownRedemptionCannotSpendAnotherCreditOrRetryAutomatically() async throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let attempts = ResetAttempts()
        let provider = QuotaProvider(id: id, displayName: "Additional", accountURL: account,
                                     connection: local, reset: .banked(website: account) { _, credit, key in
            await attempts.record(credit, key)
            throw QuotaError.unavailable
        }) { _ in
            QuotaSnapshot(windows: [.init(id: "week", title: "Weekly", remainingPercent: 10, resetAt: nil)], observedAt: .now,
                          resetCredits: .init(availableCount: 1, nextID: "earned-1", nextTitle: nil, nextExpiry: nil))
        }
        let store = UsageStore(providers: [provider], defaults: defaults)
        try await store.connect(id)
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

    private func preferences() -> (UserDefaults, String) {
        let suite = "AIUsage.Tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
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
