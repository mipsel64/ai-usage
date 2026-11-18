import Foundation
import Testing
@testable import QuotaCore

struct CodexUsageTests {
    private let executable = URL(fileURLWithPath: "/tmp/user-approved-codex")
    private let observedAt = Date(timeIntervalSince1970: 1_000)

    @Test func fetchesEveryBucketAndWindowAfterInitializing() async throws {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            ["method": "account/updated", "params": [:]],
            response(id: 2, result: usageResult(
                legacy: bucket(used: 99),
                buckets: [
                    "codex_other": bucket(
                        id: "codex_other",
                        name: "Other models",
                        used: 75,
                        reset: nil
                    ),
                    "codex": bucket(
                        used: 42.5,
                        reset: 2_000,
                        secondary: window(used: 10, reset: nil)
                    ),
                ],
                credits: [
                    "availableCount": 4,
                    "credits": [
                        credit(id: "spent", status: "redeemed"),
                        credit(id: "expired", expiresAt: 999),
                        credit(id: "next", title: "Full reset", expiresAt: 3_000),
                        credit(id: "pending", status: "redeeming"),
                    ],
                ]
            )),
        ])

        let snapshot = try await fetch(session: session)

        #expect(session.methods == ["initialize", "initialized", "account/rateLimits/read"])
        #expect(snapshot.observedAt == observedAt)
        #expect(snapshot.windows.map(\.id) == [
            "codex.primary", "codex.secondary", "codex_other.primary",
        ])
        #expect(snapshot.windows.map(\.remainingPercent) == [57.5, 90, 25])
        #expect(snapshot.windows[0].resetAt == Date(timeIntervalSince1970: 2_000))
        #expect(snapshot.windows[1].resetAt == nil)
        #expect(snapshot.windows[2].resetAt == nil)
        #expect(snapshot.resetCredits?.availableCount == 4)
        #expect(snapshot.resetCredits?.nextID == "next")
        #expect(snapshot.resetCredits?.nextTitle == "Full reset")
        #expect(snapshot.resetCredits?.nextExpiry == Date(timeIntervalSince1970: 3_000))
        #expect(session.didClose)
    }

    @Test func supportsLegacySingleBucketAndMissingResetCredits() async throws {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: [
                "rateLimits": bucket(used: 0, reset: nil),
            ]),
        ])

        let snapshot = try await fetch(session: session)

        #expect(snapshot.windows.count == 1)
        #expect(snapshot.windows[0].id == "codex.primary")
        #expect(snapshot.windows[0].remainingPercent == 100)
        #expect(snapshot.windows[0].resetAt == nil)
        #expect(snapshot.resetCredits == nil)
    }

    @Test func namesWindowsFromTheirReportedLength() async throws {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: usageResult(
                legacy: bucket(used: 0),
                buckets: [
                    "codex": bucket(used: 10, secondary: window(used: 20, reset: nil, minutes: 10_080)),
                    "codex_spark": bucket(id: "codex_spark", name: "GPT-5.3-Codex-Spark", used: 30, minutes: 10_080),
                ]
            )),
        ])

        let snapshot = try await fetch(session: session)

        #expect(snapshot.windows.map(\.id) == ["codex.primary", "codex.secondary", "codex_spark.primary"])
        #expect(snapshot.windows.map(\.title) == ["5-hour", "Weekly", "Weekly GPT-5.3-Codex-Spark"])
    }

    @Test(arguments: [
        (10_080, "Weekly"), (43_200, "Monthly"), (206, "Codex Primary"), (0, "Codex Primary"), (nil, "Codex Primary"),
    ] as [(Int?, String)])
    func namesMainBucketWithOnlyPrimaryWindow(minutes: Int?, title: String) async throws {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: ["rateLimits": bucket(used: 0, minutes: minutes)]),
        ])

        let snapshot = try await fetch(session: session)

        #expect(snapshot.windows.map(\.id) == ["codex.primary"])
        #expect(snapshot.windows.map(\.title) == [title])
    }

    @Test func keepsReadingWithMalformedLength() async throws {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: ["rateLimits": bucket(used: 25, minutes: "300")]),
        ])

        let snapshot = try await fetch(session: session)

        #expect(snapshot.windows.map(\.title) == ["Codex Primary"])
        #expect(snapshot.windows.map(\.remainingPercent) == [75])
    }

    @Test(arguments: [
        (18_000, "5-hour"), (3_600, "1-hour"), (86_400, "24-hour"), (604_800, "Weekly"), (2_592_000, "Monthly"),
        (90_000, nil), (12_345, nil), (1_800, nil), (0, nil), (-18_000, nil), (.infinity, nil), (.nan, nil),
    ] as [(Double, String?)])
    func labelsWindowLength(seconds: Double, label: String?) {
        #expect(windowLengthLabel(seconds: seconds) == label)
    }

    @Test func absentLengthHasNoLabel() {
        #expect(windowLengthLabel(seconds: nil) == nil)
    }

    @Test(arguments: [-1.0, 100.1])
    func rejectsOutOfRangeUsage(usedPercent: Double) async {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: [
                "rateLimits": bucket(used: usedPercent, reset: nil),
            ]),
        ])

        await #expect(throws: QuotaError.invalidResponse) {
            _ = try await fetch(session: session)
        }
    }

    @Test(arguments: [(401, QuotaError.unauthorized), (429, QuotaError.rateLimited)])
    func sanitizesRPCFailures(code: Int, expected: QuotaError) async {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            [
                "id": 2,
                "error": [
                    "code": code,
                    "message": "private server detail must not escape",
                ],
            ],
        ])

        await #expect(throws: expected) {
            _ = try await fetch(session: session)
        }
    }

    @Test func rejectsMalformedResponseWithoutEchoingIt() async {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            ["id": 2, "result": ["unexpected": "secret-looking raw response"]],
        ])

        await #expect(throws: QuotaError.invalidResponse) {
            _ = try await fetch(session: session)
        }
    }

    @Test func rejectsResponseWithoutAnyQuotaWindow() async {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: ["rateLimits": ["limitId": "codex"]]),
        ])

        await #expect(throws: QuotaError.invalidResponse) {
            _ = try await fetch(session: session)
        }
    }

    @Test func redeemsExactAvailableBankedCreditOnce() async throws {
        let session = FakeCodexSession(messages: redemptionMessages(
            credits: [credit(id: "chosen")],
            outcome: "reset"
        ))

        let outcome = try await redeem(session: session, creditID: "chosen")

        #expect(redemptionName(outcome) == "reset")
        #expect(session.methods == [
            "initialize", "initialized", "account/rateLimits/read",
            "account/rateLimitResetCredit/consume",
        ])
        let consume = try #require(session.sentMessages.last)
        let params = try #require(consume["params"] as? [String: Any])
        #expect(params["creditId"] as? String == "chosen")
        #expect(params["idempotencyKey"] as? String == "test-idempotency-key")
    }

    @Test(arguments: [
        UnavailableCreditScenario.redeemed,
        .redeeming,
        .unknownStatus,
        .unknownType,
        .expired,
    ])
    func refusesUnavailableExactCreditBeforeConsuming(
        scenario: UnavailableCreditScenario
    ) async throws {
        let unavailable: [String: Any]
        switch scenario {
        case .redeemed:
            unavailable = credit(id: "chosen", status: "redeemed")
        case .redeeming:
            unavailable = credit(id: "chosen", status: "redeeming")
        case .unknownStatus:
            unavailable = credit(id: "chosen", status: "unknown")
        case .unknownType:
            unavailable = credit(id: "chosen", resetType: "unknown")
        case .expired:
            unavailable = credit(id: "chosen", expiresAt: 999)
        }
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: usageResult(
                legacy: bucket(used: 100),
                credits: ["availableCount": 1, "credits": [unavailable]]
            )),
        ])

        let outcome = try await redeem(session: session, creditID: "chosen")

        #expect(redemptionName(outcome) == "noCredit")
        #expect(session.methods == ["initialize", "initialized", "account/rateLimits/read"])
    }

    @Test func refusesMissingExactCreditWhenDetailsAreUnavailable() async throws {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: usageResult(
                legacy: bucket(used: 100),
                credits: ["availableCount": 1]
            )),
        ])

        let outcome = try await redeem(session: session, creditID: "chosen")

        #expect(redemptionName(outcome) == "noCredit")
        #expect(session.methods.count == 3)
    }

    @Test func doesNotConsumeWhenBackendReportsNoCredits() async throws {
        let session = FakeCodexSession(messages: [
            response(id: 1, result: [:]),
            response(id: 2, result: usageResult(
                legacy: bucket(used: 100),
                credits: ["availableCount": 0, "credits": []]
            )),
        ])

        let outcome = try await redeem(session: session, creditID: "chosen")

        #expect(redemptionName(outcome) == "noCredit")
        #expect(session.methods.count == 3)
    }

    @Test(arguments: ["alreadyRedeemed", "nothingToReset", "noCredit"])
    func returnsDocumentedRedemptionOutcomes(rawOutcome: String) async throws {
        let session = FakeCodexSession(messages: redemptionMessages(
            credits: [credit(id: "chosen")],
            outcome: rawOutcome
        ))

        let outcome = try await redeem(session: session, creditID: "chosen")

        #expect(redemptionName(outcome) == rawOutcome)
        #expect(session.methods.filter { $0 == "account/rateLimitResetCredit/consume" }.count == 1)
    }

    @Test func rejectsEmptyIdempotencyKeyBeforeStarting() async {
        let session = FakeCodexSession()

        await #expect(throws: QuotaError.notConfigured) {
            _ = try await redeem(session: session, creditID: "chosen", idempotencyKey: "")
        }
        #expect(session.sentMessages.isEmpty)
        #expect(!session.didStart)
    }

    @Test func rejectsEmptyCreditIDBeforeStarting() async {
        let session = FakeCodexSession()

        await #expect(throws: QuotaError.notConfigured) {
            _ = try await redeem(session: session, creditID: "")
        }
        #expect(session.sentMessages.isEmpty)
        #expect(!session.didStart)
    }

    @Test func timeoutInterruptsBlockedReadAndReturns() async {
        let session = FakeCodexSession(blockReads: true)

        await #expect(throws: QuotaError.unavailable) {
            _ = try await CodexUsage.fetch(
                executable: executable,
                session: session,
                timeout: 0.02,
                observedAt: observedAt
            )
        }
        #expect(session.wasInterrupted)
    }

    @Test func rejectsNonFileExecutable() {
        #expect(throws: QuotaError.notConfigured) {
            try CodexUsage.validateExecutable(URL(string: "https://example.com/codex")!)
        }
    }

    private func redemptionName(_ redemption: Redemption) -> String {
        switch redemption {
        case .reset: "reset"
        case .alreadyRedeemed: "alreadyRedeemed"
        case .nothingToReset: "nothingToReset"
        case .noCredit: "noCredit"
        }
    }

    private func fetch(session: FakeCodexSession) async throws -> QuotaSnapshot {
        try await CodexUsage.fetch(
            executable: executable,
            session: session,
            timeout: 1,
            observedAt: observedAt
        )
    }

    private func redeem(
        session: FakeCodexSession,
        creditID: String,
        idempotencyKey: String = "test-idempotency-key"
    ) async throws -> Redemption {
        try await CodexUsage.redeem(
            executable: executable,
            creditID: creditID,
            idempotencyKey: idempotencyKey,
            session: session,
            timeout: 1,
            observedAt: observedAt
        )
    }

    private func redemptionMessages(
        availableCount: Int = 1,
        credits: [[String: Any]]?,
        outcome: String
    ) -> [[String: Any]] {
        var summary: [String: Any] = ["availableCount": availableCount]
        if let credits { summary["credits"] = credits }
        return [
            response(id: 1, result: [:]),
            response(id: 2, result: usageResult(
                legacy: bucket(used: 100),
                credits: summary
            )),
            response(id: 3, result: ["outcome": outcome]),
        ]
    }

    private func usageResult(
        legacy: [String: Any],
        buckets: [String: [String: Any]]? = nil,
        credits: [String: Any]? = nil
    ) -> [String: Any] {
        var result: [String: Any] = ["rateLimits": legacy]
        if let buckets { result["rateLimitsByLimitId"] = buckets }
        if let credits { result["rateLimitResetCredits"] = credits }
        return result
    }

    private func bucket(
        id: String = "codex",
        name: String? = nil,
        used: Double,
        reset: Double? = nil,
        minutes: Any? = 300,
        secondary: [String: Any]? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "limitId": id,
            "primary": window(used: used, reset: reset, minutes: minutes),
        ]
        if let name { result["limitName"] = name }
        if let secondary { result["secondary"] = secondary }
        return result
    }

    private func window(used: Double, reset: Double?, minutes: Any? = 300) -> [String: Any] {
        var result: [String: Any] = ["usedPercent": used]
        if let minutes { result["windowDurationMins"] = minutes }
        if let reset { result["resetsAt"] = reset }
        return result
    }

    private func credit(
        id: String,
        resetType: String = "codexRateLimits",
        status: String = "available",
        title: String? = nil,
        expiresAt: Double? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "resetType": resetType,
            "status": status,
        ]
        if let title { result["title"] = title }
        if let expiresAt { result["expiresAt"] = expiresAt }
        return result
    }

    private func response(id: Int, result: [String: Any]) -> [String: Any] {
        ["id": id, "result": result]
    }
}

enum UnavailableCreditScenario: Sendable {
    case redeemed, redeeming, unknownStatus, unknownType, expired
}

private final class FakeCodexSession: CodexUsageSession, @unchecked Sendable {
    private let condition = NSCondition()
    private var messages: [[String: Any]]
    private var sent: [[String: Any]] = []
    private let blockReads: Bool
    private var started = false
    private var closed = false
    private var interrupted = false

    init(messages: [[String: Any]] = [], blockReads: Bool = false) {
        self.messages = messages
        self.blockReads = blockReads
    }

    var sentMessages: [[String: Any]] {
        condition.lock()
        defer { condition.unlock() }
        return sent
    }

    var methods: [String] {
        sentMessages.map { $0["method"] as? String ?? "" }
    }

    var didStart: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    var didClose: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    var wasInterrupted: Bool {
        condition.lock()
        defer { condition.unlock() }
        return interrupted
    }

    func start(executable: URL) throws {
        condition.lock()
        started = true
        condition.unlock()
    }

    func send(_ message: [String: Any]) throws {
        condition.lock()
        sent.append(message)
        condition.unlock()
    }

    func readMessage() throws -> [String: Any] {
        condition.lock()
        defer { condition.unlock() }
        while blockReads && !interrupted {
            condition.wait()
        }
        guard !messages.isEmpty else { throw QuotaError.invalidResponse }
        return messages.removeFirst()
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func interrupt() {
        condition.lock()
        interrupted = true
        condition.broadcast()
        condition.unlock()
    }
}
