import Foundation

/// Identity is available only while Z.ai sign-in still holds the business token.
enum ZaiAccountIdentity {
    static func decode(user: [String: Any]?, organization: [String: Any]?) -> AccountIdentity? {
        AccountIdentity(
            email: user?["email"] as? String,
            name: user?["name"] as? String,
            organization: organization?["organizationName"] as? String
        ).sanitized()
    }
}
