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

public enum Redemption: Sendable {
    case reset, alreadyRedeemed, nothingToReset, noCredit
    /// The provider refused for now, for example during a cooldown. Nothing was used.
    case tryLater
}

public enum ResetAction: Sendable {
    case automaticOnly
    /// `redeem(access, creditID, idempotencyKey)` uses one reset; `creditID` is a `ResetOption.id`.
    case banked(website: URL, redeem: @Sendable (ProviderAccess, String, String) async throws -> Redemption)
}

public struct QuotaProvider: Identifiable, Sendable {
    public let id: ProviderID
    public let displayName: String
    public let accountURL: URL
    public let connection: ProviderConnection
    public let reset: ResetAction
    /// Shortest time between automatic quota reads; some providers rate-limit their usage endpoint.
    public let refreshInterval: TimeInterval
    public let readAccount: (@Sendable (ProviderAccess) async -> AccountIdentity?)?
    public let read: @Sendable (ProviderAccess) async throws -> QuotaSnapshot

    public init(id: ProviderID, displayName: String, accountURL: URL, connection: ProviderConnection,
                reset: ResetAction, refreshInterval: TimeInterval = 60,
                readAccount: (@Sendable (ProviderAccess) async -> AccountIdentity?)? = nil,
                read: @escaping @Sendable (ProviderAccess) async throws -> QuotaSnapshot) {
        self.id = id
        self.displayName = displayName
        self.accountURL = accountURL
        self.connection = connection
        self.reset = reset
        self.refreshInterval = refreshInterval
        self.readAccount = readAccount
        self.read = read
    }

    public var resetURL: URL? {
        switch reset {
        case .automaticOnly: nil
        case let .banked(url, _): url
        }
    }
}

public enum ProviderCatalog {
    private static let claudeUsage = URL(string: "https://claude.ai/settings/usage")!
    private static let codexUsage = URL(string: "https://chatgpt.com/codex/settings/usage")!
    private static let zaiUsage = URL(string: "https://z.ai/manage-apikey/subscription")!

    public static let all: [QuotaProvider] = [
        // /api/oauth/usage allows about one read per 2 minutes per token; a 60 s poll got HTTP 429 on 4 reads in 10.
        QuotaProvider(id: .claude, displayName: "Claude", accountURL: claudeUsage,
                      connection: .oauth,
                      reset: .banked(website: claudeUsage) { access, id, key in
                          try await ClaudeRemoteUsage.redeem(tokens: access.oauthTokens(), grantID: id, requestID: key)
                      }, refreshInterval: 180, readAccount: {
                          guard case let .oauth(tokens) = $0 else { return nil }
                          return try? await ClaudeAccountIdentity.fetch(tokens: tokens)
                      }) {
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
                      }, readAccount: {
                          guard case let .oauth(tokens) = $0 else { return nil }
                          return CodexAccountIdentity.decode(tokens: tokens)
                      }) { try await CodexRemoteUsage.fetch(tokens: $0.oauthTokens()) },
        QuotaProvider(id: .zai, displayName: "Z.ai", accountURL: zaiUsage,
                      connection: .browserLogin,
                      reset: .banked(website: zaiUsage) { access, id, key in
                          try await RemoteUsage.redeemZaiReset(credential: access.key(), recordID: id, requestID: key)
                      }, readAccount: {
                          guard case let .apiKey(key) = $0 else { return nil }
                          return try? await ZaiAccountIdentity.fetchSubscription(key: key)
                      }) {
            try await RemoteUsage.fetch(provider: .zai, credential: $0.key())
        },
        QuotaProvider(id: .kimi, displayName: "Kimi", accountURL: URL(string: "https://www.kimi.com/code/console")!,
                      connection: .oauth, reset: .automaticOnly, readAccount: {
                          guard case let .oauth(tokens) = $0 else { return nil }
                          return try? await KimiAccountIdentity.fetch(tokens: tokens)
                      }) {
            try await RemoteUsage.fetch(provider: .kimi, credential: $0.oauthTokens().accessToken)
        },
    ]
}
