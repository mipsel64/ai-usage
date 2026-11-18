import Foundation

/// Display-only identity from the official Kimi Code managed profile endpoint.
enum KimiAccountIdentity {
    private static let endpoint = URL(string: "https://api.kimi.com/coding/v1/me")!

    static func fetch(tokens: OAuthTokens) async throws -> AccountIdentity? {
        try await fetch(tokens: tokens, transport: RemoteUsage.defaultTransport())
    }

    static func fetch(tokens: OAuthTokens, transport: RemoteUsageTransport) async throws -> AccountIdentity? {
        _ = try tokens.validated()
        let body = try await RemoteUsage.fetch(
            endpoint: endpoint,
            credential: tokens.accessToken,
            transport: transport
        )
        return decode(body)
    }

    static func decode(_ body: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let userID = root["user_id"] as? String, !userID.isEmpty
        else { return nil }
        return AccountIdentity(
            email: root["email"] as? String,
            name: root["nickname"] as? String
        ).sanitized()
    }
}
