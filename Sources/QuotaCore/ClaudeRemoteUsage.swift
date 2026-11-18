import Foundation

/// Direct subscription usage from Claude Code's first-party OAuth endpoint.
/// The route is not publicly documented; its response contract is cross-checked against
/// https://github.com/FullFran/claudeops-tui/blob/main/docs/oauth-usage-endpoint.md
/// and, for the model-scoped weekly entries of `limits[]`, https://github.com/can1357/oh-my-pi/pull/4344
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
            ("five_hour", "5-hour", payload.fiveHour),
            ("seven_day", "Weekly", payload.sevenDay),
            ("seven_day_opus", "Weekly Opus", payload.sevenDayOpus),
            ("seven_day_sonnet", "Weekly Sonnet", payload.sevenDaySonnet),
        ]
        var windows = try values.compactMap { id, title, value in
            try value?.window(id: id, title: title)
        }
        for limit in payload.limits?.entries ?? [] {
            guard let window = try limit.window(), !windows.contains(where: { $0.id == window.id }) else { continue }
            windows.append(window)
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
    let limits: ClaudeLimits?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }
}

/// `limits[]` is undocumented and still changing, so a value that is not an array is ignored.
private struct ClaudeLimits: Decodable {
    let entries: [ClaudeScopedWeeklyLimit]

    init(from decoder: Decoder) throws {
        entries = (try? decoder.singleValueContainer().decode([ClaudeScopedWeeklyLimit].self)) ?? []
    }
}

/// One `limits[]` entry. Decoding never throws, so one unknown entry cannot drop the others;
/// `modelName` is nil for each entry that is not a model-scoped weekly limit.
private struct ClaudeScopedWeeklyLimit: Decodable {
    private static let maxModelNameLength = 40

    let modelName: String?
    let percent: Double?
    let resetsAt: String?
    let hasMalformedReset: Bool

    enum CodingKeys: String, CodingKey {
        case kind, percent, scope
        case resetsAt = "resets_at"
    }

    enum ScopeKeys: String, CodingKey {
        case model, surface
    }

    enum ModelKeys: String, CodingKey {
        case displayName = "display_name"
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        let scope = try? container?.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
        let model = try? scope?.nestedContainer(keyedBy: ModelKeys.self, forKey: .model)
        let isSurfaceScoped = scope.map { $0.contains(.surface) && (try? $0.decodeNil(forKey: .surface)) != true } ?? false
        if let container, (try? container.decode(String.self, forKey: .kind)) == "weekly_scoped", !isSurfaceScoped,
           let name = AccountIdentity.sanitizedText(try? model?.decode(String.self, forKey: .displayName)) {
            modelName = String(name.prefix(Self.maxModelNameLength)).trimmingCharacters(in: .whitespaces)
        } else {
            modelName = nil
        }
        percent = try? container?.decode(Double.self, forKey: .percent)
        do {
            resetsAt = try container?.decodeIfPresent(String.self, forKey: .resetsAt)
            hasMalformedReset = false
        } catch {
            resetsAt = nil
            hasMalformedReset = true
        }
    }

    func window() throws -> QuotaWindow? {
        guard let modelName else { return nil }
        let slug = modelName.lowercased()
            .replacing(#/[^\p{L}\p{N}]+/#, with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard let percent, !hasMalformedReset else { throw QuotaError.invalidResponse }
        let window = try ClaudeUsageWindow(utilization: percent, resetsAt: resetsAt)
            .window(id: "seven_day_\(slug)", title: "Weekly \(modelName)")
        return slug.isEmpty ? nil : window
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
