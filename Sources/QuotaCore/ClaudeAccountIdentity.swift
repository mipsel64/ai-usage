import Foundation

/// Display-only identity from Claude Code's OAuth profile endpoint.
enum ClaudeAccountIdentity {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    static func fetch(tokens: OAuthTokens) async throws -> AccountIdentity? {
        try await fetch(tokens: tokens, transport: RemoteUsage.defaultTransport())
    }

    static func fetch(tokens: OAuthTokens, transport: RemoteUsageTransport) async throws -> AccountIdentity? {
        _ = try tokens.validated()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 10
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let body = try await RemoteUsage.execute(request, transport: transport)
        return decode(body)
    }

    static func decode(_ body: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        return AccountIdentity(
            email: account?["email"] as? String,
            name: AccountIdentity.sanitizedText(account?["display_name"] as? String)
                ?? AccountIdentity.sanitizedText(account?["full_name"] as? String),
            plan: AccountIdentity.sanitizedText(organization?["plan_display_name"] as? String)
                ?? AccountIdentity.sanitizedText(organization?["organization_type"] as? String),
            organization: organization?["name"] as? String
        ).sanitized()
    }
}
