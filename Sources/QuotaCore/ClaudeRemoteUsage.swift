import Foundation

/// Direct subscription usage from Claude Code's first-party OAuth endpoint.
/// The route is not publicly documented; its response contract is cross-checked against
/// https://github.com/FullFran/claudeops-tui/blob/main/docs/oauth-usage-endpoint.md
public enum ClaudeRemoteUsage {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func fetch(tokens: OAuthTokens) async throws -> QuotaSnapshot {
        try await fetch(tokens: tokens, transport: RemoteUsage.defaultTransport(), observedAt: nil)
    }

    static func fetch(
        tokens: OAuthTokens,
        transport: RemoteUsageTransport,
        observedAt: Date? = nil
    ) async throws -> QuotaSnapshot {
        _ = try tokens.validated()
        let body = try await RemoteUsage.execute(request(tokens: tokens), transport: transport)
        do {
            return try decode(body, observedAt: observedAt ?? Date())
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.invalidResponse
        }
    }

    static func request(tokens: OAuthTokens) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.1.257 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        return request
    }

    private static func decode(_ body: Data, observedAt: Date) throws -> QuotaSnapshot {
        let payload = try JSONDecoder().decode(ClaudeUsagePayload.self, from: body)
        let values: [(String, String, ClaudeUsageWindow?)] = [
            ("five_hour", "5-hour limit", payload.fiveHour),
            ("seven_day", "7-day limit", payload.sevenDay),
            ("seven_day_opus", "7-day Opus limit", payload.sevenDayOpus),
            ("seven_day_sonnet", "7-day Sonnet limit", payload.sevenDaySonnet),
        ]
        var windows = try values.compactMap { id, title, value in
            try value?.window(id: id, title: title)
        }
        if let extra = payload.extraUsage, extra.isEnabled != false, let utilization = extra.utilization {
            guard utilization.isFinite, (0 ... 100).contains(utilization) else { throw QuotaError.invalidResponse }
            windows.append(QuotaWindow(
                id: "extra_usage",
                title: "Extra usage",
                remainingPercent: 100 - utilization,
                resetAt: nil
            ))
        }
        guard !windows.isEmpty else { throw QuotaError.invalidResponse }
        return QuotaSnapshot(windows: windows, observedAt: observedAt)
    }
}

private struct ClaudeUsagePayload: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let sevenDayOpus: ClaudeUsageWindow?
    let sevenDaySonnet: ClaudeUsageWindow?
    let extraUsage: ClaudeExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

private struct ClaudeUsageWindow: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    func window(id: String, title: String) throws -> QuotaWindow {
        guard utilization.isFinite, (0 ... 100).contains(utilization) else { throw QuotaError.invalidResponse }
        let resetAt: Date?
        if let resetsAt, !resetsAt.isEmpty {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: resetsAt) {
                resetAt = parsed
            } else {
                formatter.formatOptions = [.withInternetDateTime]
                guard let parsed = formatter.date(from: resetsAt) else { throw QuotaError.invalidResponse }
                resetAt = parsed
            }
        } else {
            resetAt = nil
        }
        return QuotaWindow(id: id, title: title, remainingPercent: 100 - utilization, resetAt: resetAt)
    }
}

private struct ClaudeExtraUsage: Decodable {
    let isEnabled: Bool?
    let utilization: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
    }
}
