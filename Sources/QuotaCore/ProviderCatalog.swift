import Foundation

public enum ProviderConnection: Sendable {
    case signedExecutable(requirement: SignedExecutable)
    case apiKey
    case browserLogin
    case oauth
}

public enum ProviderAccess: Sendable {
    case executable(URL)
    case apiKey(String)
    case oauth(OAuthTokens)

    public func key() throws -> String {
        guard case let .apiKey(value) = self else { throw QuotaError.notConfigured }
        return value
    }

    public func oauthTokens() throws -> OAuthTokens {
        guard case let .oauth(tokens) = self else { throw QuotaError.notConfigured }
        return tokens
    }

    public func binary() throws -> URL {
        guard case let .executable(url) = self else { throw QuotaError.notConfigured }
        return url
    }
}

public enum Redemption: Sendable { case reset, alreadyRedeemed, nothingToReset, noCredit }

public enum ResetAction: Sendable {
    case automaticOnly
    case website(URL)
    case banked(website: URL, redeem: @Sendable (ProviderAccess, String, String) async throws -> Redemption)
}

public struct QuotaProvider: Identifiable, Sendable {
    public let id: ProviderID
    public let displayName: String
    public let accountURL: URL
    public let connection: ProviderConnection
    public let reset: ResetAction
    public let read: @Sendable (ProviderAccess) async throws -> QuotaSnapshot

    public init(id: ProviderID, displayName: String, accountURL: URL, connection: ProviderConnection,
                reset: ResetAction, read: @escaping @Sendable (ProviderAccess) async throws -> QuotaSnapshot) {
        self.id = id
        self.displayName = displayName
        self.accountURL = accountURL
        self.connection = connection
        self.reset = reset
        self.read = read
    }

    public var resetURL: URL? {
        switch reset {
        case .automaticOnly: nil
        case let .website(url), let .banked(url, _): url
        }
    }

    public var supportsBankedReset: Bool {
        if case .banked = reset { return true }
        return false
    }
}

public enum ProviderCatalog {
    private static let claudeUsage = URL(string: "https://claude.ai/settings/usage")!
    private static let codexUsage = URL(string: "https://chatgpt.com/codex/settings/usage")!
    private static let zaiUsage = URL(string: "https://z.ai/manage-apikey/subscription")!

    public static let all: [QuotaProvider] = [
        QuotaProvider(id: .claude, displayName: "Claude", accountURL: claudeUsage,
                      connection: .oauth, reset: .website(claudeUsage)) {
            try await ClaudeRemoteUsage.fetch(tokens: $0.oauthTokens())
        },
        QuotaProvider(id: .codex, displayName: "Codex", accountURL: codexUsage,
                      connection: .oauth,
                      reset: .banked(website: codexUsage) { access, id, key in
                          try await CodexRemoteUsage.redeem(
                              tokens: access.oauthTokens(),
                              creditID: id,
                              idempotencyKey: key
                          )
                      }) { try await CodexRemoteUsage.fetch(tokens: $0.oauthTokens()) },
        QuotaProvider(id: .zai, displayName: "Z.ai", accountURL: zaiUsage,
                      connection: .browserLogin, reset: .website(zaiUsage)) {
            try await RemoteUsage.fetch(provider: .zai, credential: $0.key())
        },
        QuotaProvider(id: .kimi, displayName: "Kimi", accountURL: URL(string: "https://www.kimi.com/code/console")!,
                      connection: .oauth, reset: .automaticOnly) {
            try await RemoteUsage.fetch(provider: .kimi, credential: $0.oauthTokens().accessToken)
        },
    ]
}
