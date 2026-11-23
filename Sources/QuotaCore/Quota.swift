import Foundation

public struct ProviderID: Hashable, RawRepresentable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let claude = Self(rawValue: "claude")
    public static let codex = Self(rawValue: "codex")
    public static let zai = Self(rawValue: "zai")
    public static let kimi = Self(rawValue: "kimi")
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let remainingPercent: Double
    public let resetAt: Date?

    public init(id: String, title: String, remainingPercent: Double, resetAt: Date?) {
        self.id = id
        self.title = title
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
    }
}

/// One kind of banked reset that the account can use now, for example "Full reset" or "Weekly reset card".
public struct ResetOption: Codable, Equatable, Identifiable, Sendable {
    /// The provider's credit ID that one redemption uses: the credit of this kind that expires first.
    public let id: String
    public let title: String
    /// What one reset of this kind refills, when known.
    public let detail: String?
    /// Resets of this kind that can be used now.
    public let count: Int
    /// The earliest expiry of the resets of this kind; nil when none of them expires.
    public let expiry: Date?

    public init(id: String, title: String, detail: String?, count: Int, expiry: Date?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.count = count
        self.expiry = expiry
    }

    /// Groups the credits of one kind into one option that redeems the credit that expires first.
    /// A credit with no expiry sorts after every dated credit. Returns nil when no credit has a positive count.
    static func group(_ credits: [(id: String, count: Int, expiry: Date?)], title: String, detail: String?) -> ResetOption? {
        let live = credits.filter { $0.count > 0 }
        guard let first = live.min(by: { ($0.expiry ?? .distantFuture) < ($1.expiry ?? .distantFuture) }) else { return nil }
        return ResetOption(id: first.id, title: title, detail: detail, count: live.reduce(0) { $0 + $1.count }, expiry: first.expiry)
    }
}

public struct ResetCredits: Equatable, Codable, Sendable {
    /// Banked resets that the provider reports as available; the menu badge shows this number.
    public let availableCount: Int
    /// The kinds of reset that the app can redeem, in display order. Empty when the provider reports no redeemable ID.
    public let options: [ResetOption]

    public init(availableCount: Int, options: [ResetOption] = []) {
        self.availableCount = availableCount
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case availableCount, options
    }

    /// A snapshot stored by an earlier version has no `options`; it decodes with none until the next reading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decode(Int.self, forKey: .availableCount)
        options = try container.decodeIfPresent([ResetOption].self, forKey: .options) ?? []
    }
}

/// Who owns the connected subscription, as reported by the provider. Every field is optional.
public struct AccountIdentity: Equatable, Codable, Sendable {
    public let email: String?
    public let name: String?
    public let plan: String?
    public let organization: String?
    /// End of the current subscription period, or the next renewal when `renews` is true.
    public let periodEnd: Date?
    /// Whether the provider reports that the plan renews at `periodEnd`; nil when it does not say.
    public let renews: Bool?

    public init(
        email: String? = nil, name: String? = nil, plan: String? = nil, organization: String? = nil,
        periodEnd: Date? = nil, renews: Bool? = nil
    ) {
        self.email = email
        self.name = name
        self.plan = plan
        self.organization = organization
        self.periodEnd = periodEnd
        self.renews = renews
    }

    public var isEmpty: Bool { email == nil && name == nil && plan == nil && organization == nil && periodEnd == nil }
}

public struct QuotaSnapshot: Equatable, Codable, Sendable {
    public let windows: [QuotaWindow]
    public let observedAt: Date
    public let resetCredits: ResetCredits?

    public init(windows: [QuotaWindow], observedAt: Date, resetCredits: ResetCredits? = nil) {
        self.windows = windows
        self.observedAt = observedAt
        self.resetCredits = resetCredits
    }

    public static let lowQuotaThresholds = [20, 10]
    /// A window with more than this percentage left before its refresh was barely used, so its refresh does not alert.
    static let refreshAlertMaxRemainingPercent = 80.0

    public func refreshedWindows(since previous: Self) -> [QuotaWindow] {
        guard observedAt > previous.observedAt else { return [] }
        return windows.filter { window in
            guard let last = previous.windows.first(where: { $0.id == window.id }),
                  last.remainingPercent <= Self.refreshAlertMaxRemainingPercent else { return false }
            if last.remainingPercent < 100 && window.remainingPercent == 100 { return true }
            guard let before = last.resetAt, let after = window.resetAt else { return false }
            return before <= observedAt && after > observedAt && after > before
        }
    }

    // shortcut: a rolling window that moves around a threshold alerts at each downward crossing, add hysteresis if users report repeated alerts.
    public func lowWindows(since previous: Self) -> [(window: QuotaWindow, threshold: Int)] {
        guard observedAt > previous.observedAt else { return [] }
        return windows.compactMap { window in
            guard let last = previous.windows.first(where: { $0.id == window.id }) else { return nil }
            let crossed = Self.lowQuotaThresholds.filter {
                last.remainingPercent >= Double($0) && window.remainingPercent < Double($0)
            }
            return crossed.min().map { (window, $0) }
        }
    }
}

public enum QuotaError: Error, LocalizedError, Sendable {
    case notConfigured, invalidResponse, unauthorized, rateLimited, unavailable

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Set up this connection first."
        case .invalidResponse: "The provider did not return usable quota data."
        case .unauthorized: "Access denied. Check your sign-in or coding plan key."
        case .rateLimited: "Too many requests. Wait before checking again."
        case .unavailable: "Cannot read quota now. Try again later."
        }
    }
}
