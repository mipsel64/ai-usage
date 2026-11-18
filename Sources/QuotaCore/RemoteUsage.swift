import Foundation

/// Fetches account quota directly from the supported first-party provider APIs.
public enum RemoteUsage {
    private static let zaiURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    private static let zaiResetURL = URL(
        string: "https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL"
    )!
    private static let kimiURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let maximumResponseBytes = 64 * 1024

    public static func fetch(provider: ProviderID, credential: String) async throws -> QuotaSnapshot {
        try await fetch(
            provider: provider,
            credential: credential,
            transport: URLSessionRemoteUsageTransport(configuration: makeConfiguration()),
            observedAt: nil
        )
    }

    public static func defaultTransport() -> any RemoteUsageTransport {
        URLSessionRemoteUsageTransport(configuration: makeConfiguration())
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return configuration
    }

    static func fetch(
        provider: ProviderID,
        credential: String,
        transport: RemoteUsageTransport,
        observedAt: Date? = nil
    ) async throws -> QuotaSnapshot {
        let url: URL
        let decoder: (Data, Date) throws -> QuotaSnapshot
        switch provider {
        case .zai:
            url = zaiURL
            decoder = { try decodeZai($0, observedAt: $1) }
        case .kimi:
            url = kimiURL
            decoder = { try decodeKimi($0, observedAt: $1) }
        default:
            throw QuotaError.notConfigured
        }

        async let resetInventory: ZaiResetData? = provider == .zai
            ? fetchZaiResetInventory(credential: credential, transport: transport)
            : nil

        let body = try await fetch(endpoint: url, credential: credential, transport: transport)
        let receivedAt = observedAt ?? Date()
        let snapshot: QuotaSnapshot
        do {
            snapshot = try decoder(body, receivedAt)
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.invalidResponse
        }
        let inventory = try await resetInventory
        let resetCredits = inventory.map { zaiResetCredits($0, observedAt: receivedAt) }
        try Task.checkCancellation()
        return QuotaSnapshot(
            windows: snapshot.windows,
            observedAt: snapshot.observedAt,
            resetCredits: resetCredits
        )
    }

    /// Reads a compiled, first-party HTTPS endpoint using the shared quota security boundary.
    /// Never pass a URL derived from user input or a provider response.
    static func fetch(endpoint: URL, credential: String) async throws -> Data {
        try await fetch(
            endpoint: endpoint,
            credential: credential,
            transport: URLSessionRemoteUsageTransport(configuration: makeConfiguration())
        )
    }

    static func fetch(
        endpoint: URL,
        credential: String,
        transport: RemoteUsageTransport
    ) async throws -> Data {
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw QuotaError.notConfigured }
        guard key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw QuotaError.unauthorized
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let response = try await response(for: request, transport: transport)
        guard let statusCode = response.statusCode else { throw QuotaError.unavailable }
        switch statusCode {
        case 200 ... 299:
            return response.body
        case 401, 403:
            throw QuotaError.unauthorized
        case 429:
            throw QuotaError.rateLimited
        default:
            throw QuotaError.unavailable
        }
    }

    static func response(
        for request: URLRequest,
        transport: RemoteUsageTransport
    ) async throws -> RemoteUsageTransportResponse {
        guard let endpoint = request.url,
              endpoint.scheme?.lowercased() == "https",
              let host = endpoint.host,
              !host.isEmpty,
              endpoint.user == nil,
              endpoint.password == nil
        else {
            throw QuotaError.unavailable
        }

        let response: RemoteUsageTransportResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as QuotaError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw QuotaError.unavailable
        }

        guard response.body.count <= maximumResponseBytes else {
            throw QuotaError.invalidResponse
        }
        return response
    }

    static func execute(
        _ request: URLRequest,
        transport: RemoteUsageTransport
    ) async throws -> Data {
        let response = try await response(for: request, transport: transport)
        guard let statusCode = response.statusCode else { throw QuotaError.unavailable }
        switch statusCode {
        case 200 ... 299:
            return response.body
        case 401, 403:
            throw QuotaError.unauthorized
        case 429:
            throw QuotaError.rateLimited
        default:
            throw QuotaError.unavailable
        }
    }

    private static func fetchZaiResetInventory(
        credential: String,
        transport: RemoteUsageTransport
    ) async throws -> ZaiResetData? {
        // Read-only inventory used by the subscription dashboard. Never redeem a card here.
        // https://github.com/LogicIncZo/zai-usage/blob/main/zai-usage.ts
        // https://github.com/yetone/magpie/blob/main/internal/provider/zhipu_resets_test.go
        do {
            let body = try await fetch(
                endpoint: zaiResetURL,
                credential: credential,
                transport: transport
            )
            let envelope = try JSONDecoder().decode(ZaiResetEnvelope.self, from: body)
            guard envelope.code == 200, envelope.success else { return nil }
            return envelope.data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private static func zaiResetCredits(_ inventory: ZaiResetData, observedAt: Date) -> ResetCredits {
        var availableCount = 0
        var nextExpiry: Date?
        for reset in [inventory.fiveHourResets, inventory.weekResets].lazy.joined() where reset.available {
            guard let expiry = reset.expiry else {
                availableCount += 1
                continue
            }
            guard expiry > observedAt else { continue }
            availableCount += 1
            if let current = nextExpiry {
                nextExpiry = min(current, expiry)
            } else {
                nextExpiry = expiry
            }
        }
        return ResetCredits(
            availableCount: availableCount,
            nextID: nil,
            nextTitle: nil,
            nextExpiry: nextExpiry
        )
    }

    private static func decodeZai(_ body: Data, observedAt: Date) throws -> QuotaSnapshot {
        // The monitor endpoint is used by the Coding Plan dashboard and open-source CLI integrations.
        // Weekly is unit 6 with number 1; legacy readers also accept number 7 or an omitted number.
        // https://openusage.sh/docs/providers/zai/
        // https://netspeedy.github.io/zquota/windows/
        // The plan's 5-hour and weekly reset semantics are documented at
        // https://docs.z.ai/devpack/overview and https://docs.z.ai/devpack/faq.
        let envelope = try JSONDecoder().decode(ZaiEnvelope.self, from: body)
        if let code = envelope.code, code != 200 || envelope.success == false {
            switch code {
            case 401, 403:
                throw QuotaError.unauthorized
            case 429:
                throw QuotaError.rateLimited
            default:
                throw QuotaError.unavailable
            }
        }
        if envelope.code == nil, envelope.success == false {
            throw QuotaError.unavailable
        }
        guard let data = envelope.data else { throw QuotaError.invalidResponse }

        var windows: [ZaiWindowKind: QuotaWindow] = [:]
        for limit in data.limits {
            guard let kind = limit.windowKind else { continue }
            guard windows[kind] == nil else { throw QuotaError.invalidResponse }
            guard let usedPercent = limit.percentage,
                  usedPercent.isFinite,
                  (0 ... 100).contains(usedPercent)
            else {
                throw QuotaError.invalidResponse
            }

            let resetAt: Date?
            if let milliseconds = limit.nextResetTime {
                guard milliseconds > 0 else { throw QuotaError.invalidResponse }
                resetAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            } else {
                resetAt = nil
            }

            windows[kind] = QuotaWindow(
                id: kind.id,
                title: kind.title,
                remainingPercent: 100 - usedPercent,
                resetAt: resetAt
            )
        }

        let orderedWindows = ZaiWindowKind.allCases.compactMap { windows[$0] }
        guard !orderedWindows.isEmpty else { throw QuotaError.invalidResponse }
        return QuotaSnapshot(windows: orderedWindows, observedAt: observedAt)
    }

    private static func decodeKimi(_ body: Data, observedAt: Date) throws -> QuotaSnapshot {
        // Official Kimi Code CLI contract: used_ratio is 0...1 and reset_time is RFC3339.
        // https://github.com/MoonshotAI/kimi-code/blob/main/packages/oauth/src/managed-usage.ts
        // https://www.kimi.com/code/docs/en/kimi-code-cli/reference/server-api.html#get-api-v1-oauth-usage
        let response = try JSONDecoder().decode(KimiResponse.self, from: body)
        let entries: [(KimiWindowKind, KimiQuotaEntry?)] = [
            (.fiveHour, response.usages.fiveHour),
            (.weekly, response.usages.weekly),
            (.monthlyTotal, response.usages.monthlyTotal),
        ]

        var windows: [QuotaWindow] = []
        for (kind, entry) in entries {
            guard let entry else { continue }
            let usedRatio = entry.usedRatio.value
            guard usedRatio.isFinite, (0 ... 1).contains(usedRatio) else {
                throw QuotaError.invalidResponse
            }

            let resetAt: Date?
            if let value = entry.resetTime, !value.isEmpty {
                guard let date = parseRFC3339(value) else { throw QuotaError.invalidResponse }
                resetAt = date
            } else {
                resetAt = nil
            }

            windows.append(QuotaWindow(
                id: kind.id,
                title: kind.title,
                remainingPercent: (1 - usedRatio) * 100,
                resetAt: resetAt
            ))
        }

        guard !windows.isEmpty else { throw QuotaError.invalidResponse }
        return QuotaSnapshot(windows: windows, observedAt: observedAt)
    }

    fileprivate static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

public protocol RemoteUsageTransport: Sendable {
    func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse
}

public struct RemoteUsageTransportResponse: Sendable {
    public let statusCode: Int?
    public let body: Data

    public init(statusCode: Int?, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public struct URLSessionRemoteUsageTransport: RemoteUsageTransport {
    let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    public func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse {
        let session = URLSession(
            configuration: configuration,
            delegate: RedirectDenier(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            return RemoteUsageTransportResponse(statusCode: nil, body: Data())
        }
        if response.expectedContentLength > Int64(RemoteUsage.maximumResponseBytes) {
            throw QuotaError.invalidResponse
        }

        var body = Data()
        if response.expectedContentLength > 0 {
            body.reserveCapacity(Int(min(
                response.expectedContentLength,
                Int64(RemoteUsage.maximumResponseBytes)
            )))
        }
        for try await byte in bytes {
            guard body.count < RemoteUsage.maximumResponseBytes else {
                throw QuotaError.invalidResponse
            }
            body.append(byte)
        }
        return RemoteUsageTransportResponse(statusCode: response.statusCode, body: body)
    }
}

final class RedirectDenier: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct ZaiEnvelope: Decodable {
    let code: Int?
    let success: Bool?
    let data: ZaiData?

    private enum CodingKeys: String, CodingKey {
        case code
        case success
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        if code == nil || code == 200, success != false {
            data = try container.decodeIfPresent(ZaiData.self, forKey: .data)
        } else {
            data = nil
        }
    }
}

private struct ZaiData: Decodable {
    let limits: [ZaiLimit]
}

private struct ZaiResetEnvelope: Decodable {
    let code: Int
    let success: Bool
    let data: ZaiResetData?
}

private struct ZaiResetData: Decodable {
    let fiveHourResets: [ZaiResetCard]
    let weekResets: [ZaiResetCard]
}

private struct ZaiResetCard: Decodable {
    let available: Bool
    let expiry: Date?

    private enum CodingKeys: String, CodingKey {
        case available, expireTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decode(Bool.self, forKey: .available)
        let expireTime = try container.decodeIfPresent(String.self, forKey: .expireTime)
        guard available, let expireTime else {
            expiry = nil
            return
        }
        let timestamp = expireTime.replacingOccurrences(of: " ", with: "T") + "+08:00"
        guard let date = RemoteUsage.parseRFC3339(timestamp) else { throw QuotaError.invalidResponse }
        expiry = date
    }
}

private struct ZaiLimit: Decodable {
    let type: String
    let unit: Int?
    let number: Int?
    let percentage: Double?
    let nextResetTime: Int64?

    private enum CodingKeys: String, CodingKey {
        case type
        case unit
        case number
        case percentage
        case nextResetTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        guard type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT" || type == "TIME_LIMIT" else {
            unit = nil
            number = nil
            percentage = nil
            nextResetTime = nil
            return
        }
        unit = try container.decodeIfPresent(Int.self, forKey: .unit)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        percentage = try container.decodeIfPresent(Double.self, forKey: .percentage)
        nextResetTime = try container.decodeIfPresent(Int64.self, forKey: .nextResetTime)
    }

    var windowKind: ZaiWindowKind? {
        switch (type, unit, number) {
        case ("TOKENS_LIMIT", .some(3), .some(5)), ("CREDIT_LIMIT", .some(3), .some(5)),
             ("TOKENS_LIMIT", .some(3), nil), ("CREDIT_LIMIT", .some(3), nil):
            return .fiveHour
        case ("TOKENS_LIMIT", .some(6), .some(1)), ("CREDIT_LIMIT", .some(6), .some(1)),
             ("TOKENS_LIMIT", .some(6), .some(7)), ("CREDIT_LIMIT", .some(6), .some(7)),
             ("TOKENS_LIMIT", .some(6), nil), ("CREDIT_LIMIT", .some(6), nil):
            return .weekly
        case ("TIME_LIMIT", .some(5), .some(1)):
            return .monthlyTools
        default:
            return nil
        }
    }
}

private enum ZaiWindowKind: CaseIterable, Hashable {
    case fiveHour
    case weekly
    case monthlyTools

    var id: String {
        switch self {
        case .fiveHour: return "zai-5h"
        case .weekly: return "zai-weekly"
        case .monthlyTools: return "zai-monthly-tools"
        }
    }

    var title: String {
        switch self {
        case .fiveHour: return "5-hour limit"
        case .weekly: return "Weekly limit"
        case .monthlyTools: return "Monthly tools limit"
        }
    }
}

private struct KimiResponse: Decodable {
    let usages: KimiUsages
}

private struct KimiUsages: Decodable {
    let fiveHour: KimiQuotaEntry?
    let weekly: KimiQuotaEntry?
    let monthlyTotal: KimiQuotaEntry?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "limit_5h"
        case weekly = "limit_7d"
        case monthlyTotal = "limit_month_total"
    }
}

private struct KimiQuotaEntry: Decodable {
    let usedRatio: KimiRatio
    let resetTime: String?

    private enum CodingKeys: String, CodingKey {
        case usedRatio = "used_ratio"
        case resetTime = "reset_time"
    }
}

private struct KimiRatio: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
            return
        }
        if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a numeric usage ratio"
        )
    }
}

private enum KimiWindowKind {
    case fiveHour
    case weekly
    case monthlyTotal

    var id: String {
        switch self {
        case .fiveHour: return "kimi-5h"
        case .weekly: return "kimi-weekly"
        case .monthlyTotal: return "kimi-monthly-total"
        }
    }

    var title: String {
        switch self {
        case .fiveHour: return "5-hour limit"
        case .weekly: return "Weekly limit"
        case .monthlyTotal: return "Monthly limit"
        }
    }
}
