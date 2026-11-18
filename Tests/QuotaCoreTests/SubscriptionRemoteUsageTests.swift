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
            QuotaWindow(id: "five_hour", title: "5-hour limit", remainingPercent: 75, resetAt: Date(timeIntervalSince1970: 1_800_000_000.123)),
            QuotaWindow(id: "seven_day", title: "7-day limit", remainingPercent: 40, resetAt: nil),
            QuotaWindow(id: "seven_day_sonnet", title: "7-day Sonnet limit", remainingPercent: 87.5, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
    }

    @Test func claudeAddsModelScopedWeeklyLimitsAfterFlatWindows() async throws {
        let body = #"{"five_hour":{"utilization":42,"resets_at":"2026-07-21T14:10:00.268668+00:00"},"seven_day":{"utilization":28,"resets_at":null},"seven_day_opus":null,"seven_day_sonnet":null,"extra_usage":{"is_enabled":true,"utilization":10},"limits":[{"kind":"session","group":"session","percent":42,"severity":"normal","resets_at":"2026-07-21T14:10:00.268668+00:00","scope":null,"is_active":true},{"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical","resets_at":"2027-01-15T08:00:00+00:00","is_active":false,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},{"kind":"weekly_scoped","percent":5,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}"#
        let snapshot = try await fetchClaude(body)

        #expect(snapshot.windows == [
            QuotaWindow(id: "five_hour", title: "5-hour limit", remainingPercent: 58, resetAt: Date(timeIntervalSince1970: 1_784_643_000.268)),
            QuotaWindow(id: "seven_day", title: "7-day limit", remainingPercent: 72, resetAt: nil),
            QuotaWindow(id: "seven_day_fable", title: "7-day Fable limit", remainingPercent: 0, resetAt: Date(timeIntervalSince1970: 1_800_000_000)),
            QuotaWindow(id: "extra_usage", title: "Extra usage", remainingPercent: 90, resetAt: nil),
        ])
    }

    @Test func claudeKeepsTheFlatWindowWhenLimitsRepeatItsID() async throws {
        let body = #"{"seven_day_opus":{"utilization":30,"resets_at":null},"limits":[{"kind":"weekly_scoped","percent":90,"resets_at":null,"scope":{"model":{"display_name":"Opus"},"surface":null}}]}"#
        let snapshot = try await fetchClaude(body)

        #expect(snapshot.windows == [QuotaWindow(id: "seven_day_opus", title: "7-day Opus limit", remainingPercent: 70, resetAt: nil)])
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

        #expect(snapshot.windows == [QuotaWindow(id: "seven_day_fable_max", title: "7-day Fable Max limit", remainingPercent: 75, resetAt: nil)])
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
