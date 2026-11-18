import Foundation

/// Unverified JWT claims are used only for display, never for authorization.
enum CodexAccountIdentity {
    static func decode(tokens: OAuthTokens) -> AccountIdentity? {
        for token in [tokens.idToken, tokens.accessToken].compactMap({ $0 }) {
            if let identity = decode(jwt: token) { return identity }
        }
        return nil
    }

    static func decode(jwt: String) -> AccountIdentity? {
        guard let claims = decodeJWT(jwt) else { return nil }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let organizations = auth?["organizations"] as? [[String: Any]]
        let organization = organizations?.first(where: { $0["is_default"] as? Bool == true }) ?? organizations?.first
        return AccountIdentity(
            email: (claims["email"] as? String) ?? (profile?["email"] as? String),
            plan: auth?["chatgpt_plan_type"] as? String,
            organization: organization?["title"] as? String
        ).sanitized()
    }
}
