import Foundation

/// Identity is available only while Z.ai sign-in still holds the business token.
enum ZaiAccountIdentity {
    // Same read-only call and key as the official ZCode client:
    // https://github.com/zai-org/ZCode/blob/main/packages/services/src/bigmodel/codingPlanEntitlement.ts
    private static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!

    static func decode(user: [String: Any]?, organization: [String: Any]?) -> AccountIdentity? {
        AccountIdentity(
            email: user?["email"] as? String,
            name: user?["name"] as? String,
            organization: organization?["organizationName"] as? String
        ).sanitized()
    }

    /// The subscription key reaches only the current period of the active Coding Plan.
    static func fetchSubscription(key: String) async throws -> AccountIdentity? {
        try await fetchSubscription(key: key, transport: RemoteUsage.defaultTransport())
    }

    static func fetchSubscription(key: String, transport: RemoteUsageTransport) async throws -> AccountIdentity? {
        decodeSubscription(try await RemoteUsage.fetch(endpoint: subscriptionURL, credential: key, transport: transport))
    }

    static func decodeSubscription(_ body: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              root["success"] as? Bool != false,
              root["code"] == nil || [0, 200].contains(root["code"] as? Int ?? -1),
              let items = root["data"] as? [Any],
              let plan = items.lazy.compactMap({ $0 as? [String: Any] }).first(where: isActiveCodingPlan),
              let text = plan["nextRenewTime"] as? String,
              let periodEnd = parseRenewTime(text)
        else { return nil }
        // When autoRenew is off, nextRenewTime is the end of the paid period, not a charge date.
        return AccountIdentity(periodEnd: periodEnd, renews: plan["autoRenew"] as? Bool).sanitized()
    }

    private static func isActiveCodingPlan(_ item: [String: Any]) -> Bool {
        let product = [item["productId"], item["productName"]].contains {
            ($0 as? String)?.lowercased().contains("coding") == true
        }
        return product && item["status"] as? String == "VALID" && item["inCurrentPeriod"] as? Bool == true
    }

    private static func parseRenewTime(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if text.contains(" ") {
            // Same UTC+8 rule as the Z.ai reset-card expiry strings.
            return RemoteUsage.parseRFC3339(text.replacingOccurrences(of: " ", with: "T") + "+08:00")
        }
        // A plain date has no time zone; local midnight keeps the reported calendar date.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text)
    }
}
