import Foundation

public enum ProviderConnection: Sendable {
    case statusLine(toolName: String, helperName: String)
    case signedExecutable(requirement: SignedExecutable)
    case apiKey
}

public enum ProviderAccess: Sendable {
    case local
    case executable(URL)
    case apiKey(String)

    public func key() throws -> String {
        guard case let .apiKey(value) = self else { throw QuotaError.notConfigured }
        return value
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
                      connection: .statusLine(toolName: "Claude Code", helperName: "claude-quota-capture"),
                      reset: .website(claudeUsage)) { _ in try ClaudeUsage.read() },
        QuotaProvider(id: .codex, displayName: "Codex", accountURL: codexUsage,
                      connection: .signedExecutable(requirement: CodexUsage.signatureRequirement),
                      reset: .banked(website: codexUsage) { access, id, key in
                          try await CodexUsage.redeem(executable: access.binary(), creditID: id, idempotencyKey: key)
                      }) { try await CodexUsage.fetch(executable: $0.binary()) },
        QuotaProvider(id: .zai, displayName: "Z.ai", accountURL: zaiUsage,
                      connection: .apiKey, reset: .website(zaiUsage)) {
            try await RemoteUsage.fetch(provider: .zai, credential: $0.key())
        },
        QuotaProvider(id: .kimi, displayName: "Kimi", accountURL: URL(string: "https://www.kimi.com/code/console")!,
                      connection: .apiKey, reset: .automaticOnly) {
            try await RemoteUsage.fetch(provider: .kimi, credential: $0.key())
        },
    ]
}
