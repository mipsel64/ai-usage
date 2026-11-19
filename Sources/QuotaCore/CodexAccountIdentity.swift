import Foundation

/// Unverified JWT claims are used only for display, never for authorization.
enum CodexAccountIdentity {
    static func decode(tokens: OAuthTokens) -> AccountIdentity? {
        let accessIdentity = decode(jwt: tokens.accessToken, accountID: tokens.accountID)
        let idIdentity = tokens.idToken.flatMap { decode(jwt: $0, accountID: tokens.accountID) }
        guard let primary = accessIdentity else { return idIdentity }
        guard let fallback = idIdentity else { return primary }
        return AccountIdentity(
            email: primary.email ?? fallback.email,
            name: primary.name ?? fallback.name,
            plan: primary.plan ?? fallback.plan,
            organization: primary.organization ?? fallback.organization,
            periodEnd: primary.periodEnd ?? fallback.periodEnd
        ).sanitized()
    }

    static func decode(jwt: String, accountID: String? = nil) -> AccountIdentity? {
        guard let claims = decodeJWT(jwt) else { return nil }
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        if let accountID, let claim = auth?["chatgpt_account_id"],
           (claim as? String) != accountID { return nil }
        let organizations = auth?["organizations"] as? [[String: Any]]
        let organization = organizations?.first(where: { $0["is_default"] as? Bool == true }) ?? organizations?.first
        return AccountIdentity(
            email: AccountIdentity.sanitizedEmail(claims["email"] as? String)
                ?? AccountIdentity.sanitizedEmail(profile?["email"] as? String),
            name: claims["name"] as? String,
            plan: auth?["chatgpt_plan_type"] as? String,
            organization: organization?["title"] as? String,
            // Paid-until snapshot; it changes only when the token is renewed.
            periodEnd: (auth?["chatgpt_subscription_active_until"] as? String).flatMap(RemoteUsage.parseRFC3339)
        ).sanitized()
    }
}
