import Foundation
import Testing
@testable import QuotaCore

struct SubscriptionRemoteUsageTests {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_100)
    private let claudeTokens = OAuthTokens(accessToken: "claude-access", refreshToken: "claude-refresh", expiresAt: Date().addingTimeInterval(3600))
    private let codexTokens = OAuthTokens(accessToken: "codex-access", refreshToken: "codex-refresh", expiresAt: Date().addingTimeInterval(3600), accountID: "account-123")

    @Test func claudeUsesOAuthHeadersAndMapsEveryReportedWindow() async throws {
        let transport = QueuedSubscriptionTransport(responses: [
            .success(.init(statusCode: 200, body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2027-01-15T08:00:00.123Z"},"seven_day":{"utilization":60,"resets_at":null},"seven_day_opus":null,"seven_day_sonnet":{"utilization":12.5,"resets_at":"2027-01-15T08:00:00Z"},"extra_usage":{"is_enabled":false,"utilization":50}}"#.utf8))),
        ])

        let snapshot = try await ClaudeRemoteUsage.fetch(tokens: claudeTokens, transport: transport, observedAt: observedAt)
        let requests = await transport.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer claude-access")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.httpShouldHandleCookies == false)
        #expect(snapshot.observedAt == observedAt)
        #expect(snapshot.windows == [
            QuotaWindow(id: "five_hour", title: "5-hour", remainingPercent: 75, resetAt: Date(timeIntervalSince1970: 1_800_000_000.123)),
            QuotaWindow(id: "seven_day", title: "Weekly", remainingPercent: 40, resetAt: nil),
            QuotaWindow(id: "seven_day_sonnet", title: "Weekly Sonnet", remainingPercent: 87.5, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
    }

    @Test func claudeAddsModelScopedWeeklyLimitsAfterFlatWindows() async throws {
        let body = #"{"five_hour":{"utilization":42,"resets_at":"2026-07-21T14:10:00.268668+00:00"},"seven_day":{"utilization":28,"resets_at":null},"seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"is_enabled":true,"utilization":10},"limits":[{"kind":"session","group":"session","percent":42,"severity":"normal","resets_at":"2026-07-21T14:10:00.268668+00:00","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical","resets_at":"2027-01-15T08:00:00+00:00","is_active":false,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},{"kind":"weekly_scoped","percent":5,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}"#
        let snapshot = try await fetchClaude(body)

        #expect(snapshot.windows == [
            QuotaWindow(id: "five_hour", title: "5-hour", remainingPercent: 58, resetAt: Date(timeIntervalSince1970: 1_784_643_000.268)),
            QuotaWindow(id: "seven_day", title: "Weekly", remainingPercent: 72, resetAt: nil),
            QuotaWindow(id: "seven_day_fable", title: "Weekly Fable", remainingPercent: 0, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
            QuotaWindow(id: "extra_usage", title: "Extra usage", remainingPercent: 90, resetAt: nil),
        ])
    }

    @Test func claudeKeepsTheFlatWindowWhenLimitsRepeatItsID() async throws {
        let body = #"{"seven_day_opus":{"utilization":30,"resets_at":null},"limits":[{"kind":"weekly_scoped","percent":90,"resets_at":null,"scope":{"model":{"display_name":"Opus"},"surface":null}}]}"#
        let snapshot = try await fetchClaude(body)

        #expect(snapshot.windows == [QuotaWindow(id: "seven_day_opus", title: "Weekly Opus", remainingPercent: 70, resetAt: nil)])
    }

    @Test(arguments: [
        #""limits":"soon""#,
        #""limits":{"kind":"weekly_scoped"}"#,
        #""limits":[42,{"kind":7},{"kind":"weekly_scoped","percent":500,"scope":null},{"kind":"weekly_scoped","percent":500,"scope":{"model":{"display_name":"Fable"},"surface":{"id":"code"}}},{"kind":"future","percent":500,"scope":{"model":{"display_name":"Fable"}}}]"#,
    ])
    func claudeIgnoresLimitsItCannotRead(limits: String) async throws {
        let snapshot = try await fetchClaude(#"{"seven_day":{"utilization":28,"resets_at":null},"# + limits + "}")

        #expect(snapshot.windows.map(\.id) == ["seven_day"])
    }

    @Test(arguments: [#""percent":101,"resets_at":null"#, #""percent":-1,"resets_at":null"#, #""percent":"full","resets_at":null"#, #""percent":50,"resets_at":"tomorrow""#, #""percent":50,"resets_at":1800000000"#])
    func claudeRejectsMalformedModelScopedWeeklyLimit(fields: String) async throws {
        let body = #"{"seven_day":{"utilization":28,"resets_at":null},"limits":[{"kind":"weekly_scoped","# + fields + #","scope":{"model":{"display_name":"Fable"},"surface":null}}]}"#

        await #expect(throws: QuotaError.invalidResponse) {
            _ = try await fetchClaude(body)
        }
    }

    @Test func claudeCleansModelDisplayName() async throws {
        let body = #"{"limits":[{"kind":"weekly_scoped","percent":25,"resets_at":null,"scope":{"model":{"display_name":" Fa\u0007ble\u202E Max\n"},"surface":null}},{"kind":"weekly_scoped","percent":25,"resets_at":null,"scope":{"model":{"display_name":"\u0000\t"},"surface":null}}]}"#
        let snapshot = try await fetchClaude(body)

        #expect(snapshot.windows == [QuotaWindow(id: "seven_day_fable_max", title: "Weekly Fable Max", remainingPercent: 75, resetAt: nil)])
    }

    @Test func claudeKeepsNonASCIIModelName() async throws {
        let body = #"{"limits":[{"kind":"weekly_scoped","percent":25,"resets_at":null,"scope":{"model":{"display_name":"模型"},"surface":null}}]}"#
        let snapshot = try await fetchClaude(body)

        #expect(snapshot.windows.map(\.id) == ["seven_day_模型"])
        #expect(snapshot.windows.map(\.title) == ["Weekly 模型"])
    }

    @Test func claudeValidatesPunctuationOnlyModelName() async throws {
        let body = #"{"limits":[{"kind":"weekly_scoped","percent":101,"resets_at":null,"scope":{"model":{"display_name":"--"},"surface":null}}]}"#

        await #expect(throws: QuotaError.invalidResponse) {
            _ = try await fetchClaude(body)
        }
    }

    private func fetchClaude(_ body: String) async throws -> QuotaSnapshot {
        let transport = QueuedSubscriptionTransport(responses: [.success(.init(statusCode: 200, body: Data(body.utf8)))])
        return try await ClaudeRemoteUsage.fetch(tokens: claudeTokens, transport: transport, observedAt: observedAt)
    }

    @Test func codexReadsAccountScopedUsageWhenCreditInventoryIsUnavailable() async throws {
        let transport = QueuedSubscriptionTransport(responses: [
            .success(.init(statusCode: 200, body: Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":15,"reset_at":1800000000},"secondary_window":{"used_percent":40,"reset_at":1800060000}}}"#.utf8))),
            .success(.init(statusCode: 404, body: Data("not found".utf8))),
        ])

        let snapshot = try await CodexRemoteUsage.fetch(tokens: codexTokens, transport: transport, observedAt: observedAt)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(requests[1].url?.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
        for request in requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer codex-access")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
            #expect(request.httpShouldHandleCookies == false)
        }
        #expect(snapshot.windows.map(\.id) == ["codex.primary", "codex.secondary"])
        #expect(snapshot.windows.map(\.title) == ["Codex Primary", "Codex Secondary"])
        #expect(snapshot.windows.map(\.remainingPercent) == [85, 60])
        #expect(snapshot.resetCredits == nil)
    }

    @Test func codexCreditAuthenticationFailureRequiresReauthentication() async throws {
        let transport = QueuedSubscriptionTransport(responses: [
            .success(.init(statusCode: 200, body: Data(#"{"rate_limit":{"primary_window":{"used_percent":15,"reset_at":1800000000}}}"#.utf8))),
            .success(.init(statusCode: 401, body: Data("unauthorized".utf8))),
        ])

        await #expect(throws: QuotaError.unauthorized) {
            _ = try await CodexRemoteUsage.fetch(tokens: codexTokens, transport: transport, observedAt: observedAt)
        }
    }

    @Test func codexNamesWindowsFromTheirReportedLength() async throws {
        let snapshot = try await fetchCodex(#"{"rate_limit":{"primary_window":{"used_percent":15,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1800060000}},"additional_rate_limits":[{"metered_feature":"codex_spark","limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":1800060000}}},{"metered_feature":"codex_other","limit_name":"Other","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":12345,"reset_at":1800000000}}},{"limit_name":"Unnamed","rate_limit":{"primary_window":{"used_percent":30,"reset_at":1800000000}}}]}"#)
        #expect(snapshot.windows.map(\.id) == [
            "codex.primary", "codex.secondary", "codex_spark.primary", "codex_spark.secondary", "codex_other.primary", "additional-2.primary",
        ])
        #expect(snapshot.windows.map(\.title) == [
            "5-hour", "Weekly", "5-hour GPT-5.3-Codex-Spark", "Weekly GPT-5.3-Codex-Spark", "Other Primary", "Unnamed Primary",
        ])
        #expect(snapshot.windows.map(\.remainingPercent) == [85, 60, 95, 90, 80, 70])
    }

    @Test func codexAdditionalLimitWithoutRateLimitHasNoWindows() async throws {
        let snapshot = try await fetchCodex(#"{"rate_limit":{"primary_window":{"used_percent":15,"limit_window_seconds":18000,"reset_at":1800000000}},"additional_rate_limits":[{"metered_feature":"codex_other","limit_name":"Other","rate_limit":null},{"metered_feature":"codex_spark","limit_name":"Spark"}]}"#)
        #expect(snapshot.windows == [QuotaWindow(id: "codex.primary", title: "5-hour", remainingPercent: 85, resetAt: Date(timeIntervalSince1970: 1_800_000_000))])
    }

    @Test func codexChoosesMainBucketByStructureNotByName() async throws {
        let snapshot = try await fetchCodex(#"{"rate_limit":{"limit_name":"Codex CLI","primary_window":{"used_percent":15,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1800060000}},"additional_rate_limits":[{"metered_feature":"codex_other","limit_name":"Codex","rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_at":1800000000}}}]}"#)
        #expect(snapshot.windows.map(\.id) == ["codex.primary", "codex.secondary", "codex_other.primary"])
        #expect(snapshot.windows.map(\.title) == ["5-hour", "Weekly", "Weekly Codex"])
    }

    @Test(arguments: [
        #"[{"metered_feature":"codex_spark","limit_name":"A","rate_limit":{"primary_window":{"used_percent":5,"reset_at":1800000000}}},{"metered_feature":"codex_spark","limit_name":"B","rate_limit":{"primary_window":{"used_percent":5,"reset_at":1800000000}}}]"#,
        #"[{"metered_feature":"codex_spark","limit_name":"A","rate_limit":{"primary_window":{"used_percent":100.1,"reset_at":1800000000}}}]"#,
    ])
    func codexRejectsInvalidAdditionalLimit(additional: String) async {
        await #expect(throws: QuotaError.invalidResponse) {
            _ = try await fetchCodex(#"{"rate_limit":{"primary_window":{"used_percent":15,"reset_at":1800000000}},"additional_rate_limits":"# + additional + "}")
        }
    }

    @Test(arguments: [
        ("604800", "Weekly"), ("2592000", "Monthly"), ("12345", "Codex Primary"), ("0", "Codex Primary"),
        (#""604800""#, "Codex Primary"), ("null", "Codex Primary"),
    ])
    func codexNamesMainBucketWithOnlyPrimaryWindow(length: String, title: String) async throws {
        let snapshot = try await fetchCodex(#"{"rate_limit":{"primary_window":{"used_percent":15,"limit_window_seconds":"# + length + #","reset_at":1800000000}}}"#)
        #expect(snapshot.windows == [QuotaWindow(id: "codex.primary", title: title, remainingPercent: 85, resetAt: Date(timeIntervalSince1970: 1_800_000_000))])
    }

    private func fetchCodex(_ body: String) async throws -> QuotaSnapshot {
        let transport = QueuedSubscriptionTransport(responses: [
            .success(.init(statusCode: 200, body: Data(body.utf8))),
            .success(.init(statusCode: 404, body: Data("not found".utf8))),
        ])
        return try await CodexRemoteUsage.fetch(tokens: codexTokens, transport: transport, observedAt: observedAt)
    }
}

private actor QueuedSubscriptionTransport: RemoteUsageTransport {
    typealias Result = Swift.Result<RemoteUsageTransportResponse, Error>
    private var responses: [Result]
    private(set) var requests: [URLRequest] = []

    init(responses: [Result]) {
        self.responses = responses
    }

    func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw QuotaError.unavailable }
        return try responses.removeFirst().get()
    }
}
