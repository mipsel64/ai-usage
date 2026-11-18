import Foundation

/// Unverified JWT claims are used only for display, never for authorization.
enum CodexAccountIdentity {
    static func decode(tokens: OAuthTokens) -> AccountIdentity? {
        let idIdentity = tokens.idToken.flatMap { decode(jwt: $0) }
        let accessIdentity = decode(jwt: tokens.accessToken)
        guard let primary = idIdentity else { return accessIdentity }
        guard let fallback = accessIdentity else { return primary }
        return AccountIdentity(
            email: primary.email ?? fallback.email,
            name: primary.name ?? fallback.name,
            plan: primary.plan ?? fallback.plan,
            organization: primary.organization ?? fallback.organization
        ).sanitized()
    }

    static func decode(jwt: String) -> AccountIdentity? {
        guard let claims = decodeJWT(jwt) else { return nil }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let organizations = auth?["organizations"] as? [[String: Any]]
        let organization = organizations?.first(where: { $0["is_default"] as? Bool == true }) ?? organizations?.first
        return AccountIdentity(
            email: AccountIdentity.sanitizedEmail(claims["email"] as? String)
                ?? AccountIdentity.sanitizedEmail(profile?["email"] as? String),
            name: claims["name"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String,
            organization: organization?["title"] as? String
        ).sanitized()
    }
}
