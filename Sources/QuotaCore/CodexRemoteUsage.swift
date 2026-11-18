import Foundation

/// Account-scoped Codex subscription usage and earned reset credits.
/// Endpoint and redemption contract: https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/rate_limit_resets.rs
public enum CodexRemoteUsage {
    private static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let creditsEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private static let consumeEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!

    public static func fetch(tokens: OAuthTokens) async throws -> QuotaSnapshot {
        try await fetch(tokens: tokens, transport: RemoteUsage.defaultTransport(), observedAt: nil)
    }

    static func fetch(
        tokens: OAuthTokens,
        transport: RemoteUsageTransport,
        observedAt: Date? = nil
    ) async throws -> QuotaSnapshot {
        _ = try tokens.validated()
        let usage = try await RemoteUsage.execute(
            try getRequest(url: usageEndpoint, tokens: tokens),
            transport: transport
        )
        let credits: Data?
        do {
            credits = try await RemoteUsage.execute(
                try getRequest(url: creditsEndpoint, tokens: tokens),
                transport: transport
            )
        } catch QuotaError.unauthorized {
            throw QuotaError.unauthorized
        } catch {
            credits = nil
        }
        do {
            return try decodeSnapshot(usage: usage, credits: credits, observedAt: observedAt ?? Date())
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.invalidResponse
        }
    }

    public static func redeem(
        tokens: OAuthTokens,
        creditID: String,
        idempotencyKey: String
    ) async throws -> Redemption {
        try await redeem(
            tokens: tokens,
            creditID: creditID,
            idempotencyKey: idempotencyKey,
            transport: RemoteUsage.defaultTransport(),
            observedAt: nil
        )
    }

    static func redeem(
        tokens: OAuthTokens,
        creditID: String,
        idempotencyKey: String,
        transport: RemoteUsageTransport,
        observedAt: Date? = nil
    ) async throws -> Redemption {
        _ = try tokens.validated()
        guard !creditID.isEmpty, creditID.count <= 1024,
              !idempotencyKey.isEmpty, idempotencyKey.count <= 256,
              creditID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              idempotencyKey.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw QuotaError.notConfigured }

        let inventoryBody = try await RemoteUsage.execute(
            try getRequest(url: creditsEndpoint, tokens: tokens),
            transport: transport
        )
        let inventory = try decode(CodexResetInventory.self, from: inventoryBody)
        let eligible = try inventory.eligible(observedAt: observedAt ?? Date())
        guard eligible.summary.availableCount > 0 else { return .noCredit }
        guard eligible.ids.contains(creditID) else { return .noCredit }

        var request = try getRequest(url: consumeEndpoint, tokens: tokens)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "redeem_request_id": idempotencyKey,
                "credit_id": creditID,
            ], options: [.sortedKeys])
        } catch {
            throw QuotaError.invalidResponse
        }
        let body = try await RemoteUsage.execute(request, transport: transport)
        let response = try decode(CodexConsumeResponse.self, from: body)
        switch response.code {
        case "reset": return .reset
        case "already_redeemed": return .alreadyRedeemed
        case "nothing_to_reset": return .nothingToReset
        case "no_credit": return .noCredit
        default: throw QuotaError.invalidResponse
        }
    }

    static func getRequest(url: URL, tokens: OAuthTokens) throws -> URLRequest {
        guard let accountID = tokens.accountID, !accountID.isEmpty else { throw QuotaError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func decodeSnapshot(usage: Data, credits: Data?, observedAt: Date) throws -> QuotaSnapshot {
        let payload = try decode(CodexUsagePayload.self, from: usage)
        let inventory = try credits.map { try decode(CodexResetInventory.self, from: $0) }
        var buckets: [(String, CodexRateBucket)] = []
        if let primary = payload.rateLimit {
            buckets.append((primary.limitID ?? "codex", primary))
        }
        for (index, additional) in (payload.additionalRateLimits ?? []).enumerated() {
            buckets.append((additional.limitID ?? "additional-\(index)", additional))
        }

        var windows: [QuotaWindow] = []
        var identifiers = Set<String>()
        for (fallbackID, bucket) in buckets {
            let id = bucket.limitID ?? fallbackID
            let title = bucket.limitName ?? (id == "codex" ? "Codex" : id)
            if let primary = bucket.primaryWindow {
                let windowID = "\(id).primary"
                guard identifiers.insert(windowID).inserted else { throw QuotaError.invalidResponse }
                windows.append(try primary.window(id: windowID, title: codexWindowTitle(bucket: title, slot: "Primary", seconds: primary.limitWindowSeconds)))
            }
            if let secondary = bucket.secondaryWindow {
                let windowID = "\(id).secondary"
                guard identifiers.insert(windowID).inserted else { throw QuotaError.invalidResponse }
                windows.append(try secondary.window(id: windowID, title: codexWindowTitle(bucket: title, slot: "Secondary", seconds: secondary.limitWindowSeconds)))
            }
        }
        guard !windows.isEmpty else { throw QuotaError.invalidResponse }
        if let reported = payload.rateLimitResetCredits?.availableCount, reported < 0 {
            throw QuotaError.invalidResponse
        }
        let resetCredits: ResetCredits?
        if let inventory {
            resetCredits = try inventory.eligible(observedAt: observedAt).summary
        } else if let reported = payload.rateLimitResetCredits?.availableCount {
            resetCredits = ResetCredits(availableCount: reported, nextID: nil, nextTitle: nil, nextExpiry: nil)
        } else {
            resetCredits = nil
        }
        return QuotaSnapshot(windows: windows, observedAt: observedAt, resetCredits: resetCredits)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: body) }
        catch { throw QuotaError.invalidResponse }
    }
}

private struct CodexUsagePayload: Decodable {
    let rateLimit: CodexRateBucket?
    let additionalRateLimits: [CodexRateBucket]?
    let rateLimitResetCredits: CodexResetSummary?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case rateLimitResetCredits = "rate_limit_reset_credits"
    }
}

private struct CodexRateBucket: Decodable {
    let limitID: String?
    let limitName: String?
    let primaryWindow: CodexRateWindow?
    let secondaryWindow: CodexRateWindow?

    enum CodingKeys: String, CodingKey {
        case limitID = "limit_id"
        case limitName = "limit_name"
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexRateWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Double?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        // The length only names the window, so a malformed length must not reject the reading.
        limitWindowSeconds = try? container.decodeIfPresent(Double.self, forKey: .limitWindowSeconds)
        resetAt = try container.decodeIfPresent(Double.self, forKey: .resetAt)
    }

    func window(id: String, title: String) throws -> QuotaWindow {
        guard usedPercent.isFinite, (0 ... 100).contains(usedPercent) else { throw QuotaError.invalidResponse }
        if let resetAt, !resetAt.isFinite { throw QuotaError.invalidResponse }
        return QuotaWindow(
            id: id,
            title: title,
            remainingPercent: 100 - usedPercent,
            resetAt: resetAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private struct CodexResetSummary: Decodable {
    let availableCount: Int

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}

private struct CodexResetInventory: Decodable {
    let availableCount: Int
    let credits: [CodexResetCredit]

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }

    func eligible(observedAt: Date) throws -> (summary: ResetCredits, ids: Set<String>) {
        guard availableCount >= 0 else { throw QuotaError.invalidResponse }
        let eligible = try credits.filter { credit in
            guard credit.status == "available",
                  credit.resetType == "codex_rate_limits" || credit.resetType == "codexRateLimits"
            else { return false }
            guard let expiry = credit.expiresAt else { return true }
            guard let date = Self.parseDate(expiry) else { throw QuotaError.invalidResponse }
            return date > observedAt
        }
        let next = eligible.first
        return (
            ResetCredits(
                availableCount: availableCount,
                nextID: next?.id,
                nextTitle: next?.title,
                nextExpiry: try next?.expiresAt.map { value in
                    guard let date = Self.parseDate(value) else { throw QuotaError.invalidResponse }
                    return date
                }
            ),
            Set(eligible.map(\.id))
        )
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct CodexResetCredit: Decodable {
    let id: String
    let resetType: String
    let status: String
    let expiresAt: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case id
        case resetType = "reset_type"
        case status
        case expiresAt = "expires_at"
        case title
    }
}

private struct CodexConsumeResponse: Decodable {
    let code: String
}
