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

public struct ResetCredits: Equatable, Codable, Sendable {
    public let availableCount: Int
    public let nextID: String?
    public let nextTitle: String?
    public let nextExpiry: Date?

    public init(availableCount: Int, nextID: String?, nextTitle: String?, nextExpiry: Date?) {
        self.availableCount = availableCount
        self.nextID = nextID
        self.nextTitle = nextTitle
        self.nextExpiry = nextExpiry
    }
}

/// Who owns the connected subscription, as reported by the provider. Every field is optional.
public struct AccountIdentity: Equatable, Codable, Sendable {
    public let email: String?
    public let name: String?
    public let plan: String?
    public let organization: String?

    public init(email: String? = nil, name: String? = nil, plan: String? = nil, organization: String? = nil) {
        self.email = email
        self.name = name
        self.plan = plan
        self.organization = organization
    }

    public var isEmpty: Bool { email == nil && name == nil && plan == nil && organization == nil }
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

    public func refreshedWindows(since previous: Self) -> [QuotaWindow] {
        guard observedAt > previous.observedAt else { return [] }
        return windows.filter { window in
            guard let last = previous.windows.first(where: { $0.id == window.id }) else { return false }
            if last.remainingPercent < 100 && window.remainingPercent == 100 { return true }
            guard let before = last.resetAt, let after = window.resetAt else { return false }
            return before <= observedAt && after > observedAt && after > before
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
