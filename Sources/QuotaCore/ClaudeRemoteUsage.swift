import Foundation

/// Direct subscription usage from Claude Code's first-party OAuth endpoint.
/// The route is not publicly documented; its response contract is cross-checked against
/// https://github.com/FullFran/claudeops-tui/blob/main/docs/oauth-usage-endpoint.md
/// and, for the model-scoped weekly entries of `limits[]`, https://github.com/can1357/oh-my-pi/pull/4344
public enum ClaudeRemoteUsage {
    /// `cedar_ember=1` adds the limit-reset inventory that claude.ai lists under "Limit resets".
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")!
    private static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    public static func fetch(tokens: OAuthTokens) async throws -> QuotaSnapshot {
        try await fetch(tokens: tokens, transport: RemoteUsage.defaultTransport(), observedAt: nil)
    }

    static func fetch(
        tokens: OAuthTokens,
        transport: RemoteUsageTransport,
        observedAt: Date? = nil,
        defaults: UserDefaults = .standard
    ) async throws -> QuotaSnapshot {
        _ = try tokens.validated()
        let request = try request(tokens: tokens, cliVersion: ClaudeCodeVersion.current(in: defaults))
        let body = try await RemoteUsage.execute(request, transport: transport)
        do {
            return try decode(body, observedAt: observedAt ?? Date())
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.invalidResponse
        }
    }

    static func request(tokens: OAuthTokens, cliVersion: String) throws -> URLRequest {
        guard ClaudeCodeVersion.isValid(cliVersion) else { throw QuotaError.notConfigured }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/\(cliVersion) (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        return request
    }

    public static func redeem(tokens: OAuthTokens, grantID: String, requestID: String) async throws -> Redemption {
        try await redeem(tokens: tokens, grantID: grantID, requestID: requestID, transport: RemoteUsage.defaultTransport())
    }

    static func redeem(
        tokens: OAuthTokens,
        grantID: String,
        requestID: String,
        transport: RemoteUsageTransport,
        defaults: UserDefaults = .standard
    ) async throws -> Redemption {
        _ = try tokens.validated()
        guard grantID.wholeMatch(of: #/^[a-z0-9_-]{1,40}$/#) != nil,
              requestID.wholeMatch(of: #/^[A-Za-z0-9_-]{1,64}$/#) != nil
        else { throw QuotaError.notConfigured }

        var profileRequest = URLRequest(url: profileEndpoint)
        profileRequest.httpMethod = "GET"
        profileRequest.cachePolicy = .reloadIgnoringLocalCacheData
        profileRequest.httpShouldHandleCookies = false
        profileRequest.timeoutInterval = 10
        profileRequest.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        profileRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        profileRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        profileRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let profileBody = try await RemoteUsage.execute(profileRequest, transport: transport)
        guard let profile = try? JSONSerialization.jsonObject(with: profileBody) as? [String: Any],
              let organization = profile["organization"] as? [String: Any],
              let identifier = organization["uuid"] as? String,
              let uuid = UUID(uuidString: identifier)
        else { throw QuotaError.invalidResponse }

        let endpoint = URL(string: "https://api.anthropic.com/api/organizations/\(uuid.uuidString.lowercased())/reset_rate_limits")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/\(ClaudeCodeVersion.current(in: defaults)) (external, cli)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_id": grantID,
                "program": "cedar_ember",
                "request_id": requestID,
            ], options: [.sortedKeys])
        } catch {
            throw QuotaError.invalidResponse
        }
        let body = try await RemoteUsage.execute(request, transport: transport)
        let response: ClaudeRedemptionResponse
        do {
            response = try JSONDecoder().decode(ClaudeRedemptionResponse.self, from: body)
        } catch {
            throw QuotaError.invalidResponse
        }
        switch response.result {
        case "reset": return .reset
        case "already_used": return .alreadyRedeemed
        case "not_limited": return .nothingToReset
        case "ineligible": return .noCredit
        case "cooldown": return .tryLater
        default: throw QuotaError.invalidResponse
        }
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
        return QuotaSnapshot(
            windows: windows,
            observedAt: observedAt,
            resetCredits: payload.resetInventory?.credits(observedAt: observedAt)
        )
    }
}

private struct ClaudeRedemptionResponse: Decodable {
    let result: String
}

private struct ClaudeUsagePayload: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?
    let sevenDayOpus: ClaudeUsageWindow?
    let sevenDaySonnet: ClaudeUsageWindow?
    let extraUsage: ClaudeExtraUsage?
    let limits: ClaudeLimits?
    let resetInventory: ClaudeResetInventory?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
        case resetInventory = "cedar_ember"
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

/// The `cedar_ember` reset inventory: full, weekly, 5-hour and Fable resets. Contract cross-checked against
/// https://github.com/pingdotgg/t3code/blob/main/apps/server/src/provider/claudeResetCredits.ts
/// Decoding never throws, so an unreadable inventory cannot hide the quota windows.
private struct ClaudeResetInventory: Decodable {
    let eligible: Bool
    let grants: [ClaudeResetGrant]

    enum CodingKeys: String, CodingKey {
        case eligible, grants
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        eligible = (try? container?.decode(Bool.self, forKey: .eligible)) == true
        grants = (try? container?.decode([ClaudeResetGrant].self, forKey: .grants)) ?? []
    }

    func credits(observedAt: Date) -> ResetCredits? {
        guard eligible else { return nil }
        let live = grants.filter { $0.usableResets > 0 && $0.endsAt.map { $0 > observedAt } ?? true }
        let options = ClaudeResetKind.allCases.compactMap { kind in
            ResetOption.group(
                live.filter { $0.kind == kind }.map { ($0.id, $0.usableResets, $0.endsAt) },
                title: kind.title,
                detail: kind.detail
            )
        }
        return ResetCredits(
            availableCount: options.reduce(0) { $0 + $1.count },
            options: options
        )
    }
}

private enum ClaudeResetKind: CaseIterable {
    case full, weekly, session, fable

    var title: String {
        switch self {
        case .full: "Full reset"
        case .weekly: "Weekly reset"
        case .session: "5-hour reset"
        case .fable: "Fable reset"
        }
    }

    var detail: String {
        switch self {
        case .full: "Refills your 5-hour and weekly limits."
        case .weekly: "Refills your weekly limit."
        case .session: "Refills your 5-hour limit."
        case .fable: "Gives back the weekly usage that Fable models used. It does not reset your whole week."
        }
    }
}

/// One `grants[]` entry; `usableResets` is 0 for each entry that is unreadable, paused or not usable now.
private struct ClaudeResetGrant: Decodable {
    /// Bounds each count, so the sum of all grants in a 64 KiB response cannot overflow.
    private static let maxResets = 99

    let id: String
    let usableResets: Int
    let endsAt: Date?
    let kind: ClaudeResetKind

    enum CodingKeys: String, CodingKey {
        case id, paused, type, clears
        case resetsLeft = "resets_left"
        case endsAt = "ends_at"
        case usableNow = "usable_now"
        case givesBackWeekly = "gives_back_weekly"
    }

    init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedID = try container.decode(String.self, forKey: .id)
            let left = try container.decode(Int.self, forKey: .resetsLeft)
            let paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? false
            let usableNow = try container.decodeIfPresent(Bool.self, forKey: .usableNow) ?? false
            let decodedEndsAt = try container.decodeIfPresent(String.self, forKey: .endsAt).map(ClaudeUsageWindow.date)
            let type = try? container.decode(String.self, forKey: .type)
            let givesBackWeekly = try container.decodeIfPresent(Bool.self, forKey: .givesBackWeekly)
            let clears = try container.decodeIfPresent([ClaudeResetClear].self, forKey: .clears) ?? []
            let decodedKind: ClaudeResetKind
            if givesBackWeekly == true {
                decodedKind = .fable
            } else if let type, let declared = ClaudeResetKind(rawValue: type) {
                decodedKind = declared
            } else {
                let session = clears.contains { $0.name == "five_hour" }
                let other = clears.contains { $0.name != "five_hour" }
                decodedKind = session && !other ? .session : other && !session ? .weekly : .full
            }
            id = decodedID
            usableResets = usableNow && !paused && (0 ... Self.maxResets).contains(left)
                && decodedID.wholeMatch(of: #/^[a-z0-9_-]{1,40}$/#) != nil ? left : 0
            endsAt = decodedEndsAt
            kind = decodedKind
        } catch {
            id = ""
            usableResets = 0
            endsAt = nil
            kind = .full
        }
    }
}

private struct ClaudeResetClear: Decodable {
    let name: String?

    init(from decoder: Decoder) throws {
        name = try? decoder.singleValueContainer().decode(String.self)
    }
}

private extension ClaudeResetKind {
    init?(rawValue: String) {
        switch rawValue {
        case "full": self = .full
        case "weekly": self = .weekly
        case "session": self = .session
        default: return nil
        }
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
        let resetAt = try resetsAt.flatMap { $0.isEmpty ? nil : try Self.date($0) }
        return QuotaWindow(id: id, title: title, remainingPercent: 100 - utilization, resetAt: resetAt)
    }

    static func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: text) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        guard let parsed = formatter.date(from: text) else { throw QuotaError.invalidResponse }
        return parsed
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
