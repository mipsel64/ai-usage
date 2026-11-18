import Foundation

/// Z.ai's ZCode-compatible authorization-code flow. The short-lived OAuth token is
/// exchanged for an app-owned durable API key; neither OAuth token is retained.
public enum ZaiOAuth {
    private static let clientID = "client_P8X5CMWmlaRO9gyO-KSqtg"
    private static let authorizeURL = URL(string: "https://chat.z.ai/api/oauth/authorize")!
    private static let tokenURL = URL(string: "https://zcode.z.ai/api/v1/oauth/token")!
    private static let businessLoginURL = URL(string: "https://api.z.ai/api/auth/z/login")!
    private static let customerURL = URL(string: "https://api.z.ai/api/biz/customer/getCustomerInfo")!
    private static let businessBase = "https://api.z.ai/api/biz/v1/organization"
    private static let redirectURI = "zcode://zai-auth/callback"
    private static let keyName = "AI Usage"

    public static func authorizationURL(state: String) throws -> URL {
        try validateState(state)
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw OAuthError.invalidResponse }
        return url
    }

    public static func parseAuthorizationInput(
        _ input: String,
        expectedState: String
    ) throws -> (code: String, state: String) {
        try validateState(expectedState)
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16 * 1024 else { throw OAuthError.invalidResponse }
        var code: String?
        var state: String?
        var denied = false

        if value.contains("#"), !value.contains("://") {
            let pieces = value.split(separator: "#", omittingEmptySubsequences: false)
            guard pieces.count == 2 else { throw OAuthError.invalidResponse }
            code = String(pieces[0])
            state = String(pieces[1])
        } else {
            guard let components = URLComponents(string: value),
                  components.scheme?.lowercased() == "zcode",
                  components.host?.lowercased() == "zai-auth",
                  components.path == "/callback",
                  components.user == nil, components.password == nil,
                  components.port == nil, components.fragment == nil
            else { throw OAuthError.invalidResponse }
            let items = components.queryItems ?? []
            code = try uniqueQueryValue("code", in: items)
            state = try uniqueQueryValue("state", in: items)
            denied = items.contains(where: { $0.name == "error" })
        }

        guard let state, state == expectedState else { throw OAuthError.unauthorized }
        if denied { throw OAuthError.denied }
        guard let code else { throw OAuthError.invalidResponse }
        try validateSecret(code, maximumBytes: 4096)
        return (code, state)
    }

    public static func exchange(
        code: String,
        state: String,
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport()
    ) async throws -> String {
        try validateState(state)
        try validateSecret(code, maximumBytes: 4096)
        try Task.checkCancellation()
        let token = try await post(
            tokenURL,
            fields: ["provider": "zai", "code": code, "redirect_uri": redirectURI, "state": state],
            authorization: nil,
            transport: transport
        )
        let tokenData = try unwrap(token)
        guard let object = tokenData as? [String: Any],
              let zai = object["zai"] as? [String: Any],
              let accessToken = try secret(zai["access_token"], maximumBytes: 16 * 1024)
        else { throw OAuthError.invalidResponse }
        return try await mintKey(oauthAccessToken: accessToken, transport: transport)
    }

    private static func mintKey(
        oauthAccessToken: String,
        transport: any RemoteUsageTransport
    ) async throws -> String {
        let login = try unwrap(try await post(
            businessLoginURL,
            fields: ["token": oauthAccessToken],
            authorization: nil,
            transport: transport
        ))
        guard let loginObject = login as? [String: Any],
              let businessToken = try secret(loginObject["access_token"], maximumBytes: 16 * 1024)
                ?? secret(loginObject["accessToken"], maximumBytes: 16 * 1024)
        else { throw OAuthError.invalidResponse }
        let authorization = "Bearer \(businessToken)"

        let customer = try unwrap(try await get(customerURL, authorization: authorization, transport: transport))
        guard let customerObject = customer as? [String: Any],
              let organizations = customerObject["organizations"] as? [[String: Any]],
              !organizations.isEmpty
        else { throw OAuthError.invalidResponse }
        let organization = organizations.first(where: { $0["isDefault"] as? Bool == true }) ?? organizations[0]
        guard let projects = organization["projects"] as? [[String: Any]], !projects.isEmpty,
              let organizationID = try pathIdentifier(organization["organizationId"])
        else { throw OAuthError.invalidResponse }
        let project = projects.first(where: { $0["isDefault"] as? Bool == true }) ?? projects[0]
        guard let projectID = try pathIdentifier(project["projectId"]) else { throw OAuthError.invalidResponse }
        let keysURL = URL(string: "\(businessBase)/\(organizationID)/projects/\(projectID)/api_keys")!

        let listed = try unwrap(try await get(keysURL, authorization: authorization, transport: transport))
        let existing = keyArray(listed).first(where: { $0["name"] as? String == keyName })
        let record: [String: Any]
        if let existing {
            record = existing
        } else {
            let created = try unwrap(try await post(
                keysURL,
                fields: ["name": keyName],
                authorization: authorization,
                transport: transport
            ))
            guard let object = created as? [String: Any] else { throw OAuthError.invalidResponse }
            record = object
        }
        guard let apiKey = try pathIdentifier(record["apiKey"]) else { throw OAuthError.invalidResponse }
        let copyURL = URL(string: "\(keysURL.absoluteString)/copy/\(apiKey)")!
        let copied = try unwrap(try await get(copyURL, authorization: authorization, transport: transport))
        guard let copiedObject = copied as? [String: Any],
              let secretKey = try secret(copiedObject["secretKey"], maximumBytes: 4096)
        else { throw OAuthError.invalidResponse }
        let minted = "\(apiKey).\(secretKey)"
        guard minted.split(separator: ".", omittingEmptySubsequences: false).count == 2 else {
            throw OAuthError.invalidResponse
        }
        return minted
    }

    private static func get(
        _ url: URL,
        authorization: String,
        transport: any RemoteUsageTransport
    ) async throws -> Any {
        try await request(url, method: "GET", fields: nil, authorization: authorization, transport: transport)
    }

    private static func post(
        _ url: URL,
        fields: [String: String],
        authorization: String?,
        transport: any RemoteUsageTransport
    ) async throws -> Any {
        try await request(url, method: "POST", fields: fields, authorization: authorization, transport: transport)
    }

    private static func request(
        _ url: URL,
        method: String,
        fields: [String: String]?,
        authorization: String?,
        transport: any RemoteUsageTransport
    ) async throws -> Any {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let fields {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { request.httpBody = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) }
            catch { throw OAuthError.invalidResponse }
        }
        let response: RemoteUsageTransportResponse
        do { response = try await RemoteUsage.response(for: request, transport: transport) }
        catch is CancellationError { throw CancellationError() }
        catch QuotaError.invalidResponse { throw OAuthError.invalidResponse }
        catch { throw OAuthError.unavailable }
        guard let status = response.statusCode else { throw OAuthError.unavailable }
        guard (200 ... 299).contains(status) else {
            if status == 400 || status == 401 || status == 403 { throw OAuthError.unauthorized }
            throw OAuthError.unavailable
        }
        do { return try JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed]) }
        catch { throw OAuthError.invalidResponse }
    }

    private static func unwrap(_ body: Any) throws -> Any {
        guard let object = body as? [String: Any], object["code"] != nil || object["success"] != nil else {
            return body
        }
        let code = object["code"]
        let validCode = code == nil || (code as? Int).map({ $0 == 0 || $0 == 200 }) == true
            || (code as? String).map({ $0 == "0" || $0 == "200" }) == true
        if let success = object["success"], success as? Bool == nil { throw OAuthError.invalidResponse }
        guard validCode, object["success"] as? Bool != false else {
            if let value = (code as? Int) ?? Int(code as? String ?? "") {
                if value == 429 || value >= 500 { throw OAuthError.unavailable }
            }
            throw OAuthError.unauthorized
        }
        return object["data"] ?? object
    }

    private static func keyArray(_ value: Any) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        guard let object = value as? [String: Any] else { return [] }
        for field in ["list", "keys", "apiKeys", "records"] {
            if let array = object[field] as? [[String: Any]] { return array }
        }
        return []
    }

    private static func uniqueQueryValue(_ name: String, in items: [URLQueryItem]) throws -> String? {
        let matches = items.filter { $0.name == name }
        guard matches.count <= 1 else { throw OAuthError.invalidResponse }
        return matches.first?.value
    }

    private static func validateState(_ state: String) throws {
        guard (32 ... 128).contains(state.count), state.utf8.allSatisfy({ (33 ... 126).contains($0) }) else {
            throw OAuthError.invalidResponse
        }
    }

    private static func validateSecret(_ value: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value.utf8.allSatisfy({ (33 ... 126).contains($0) })
        else { throw OAuthError.invalidResponse }
    }

    private static func secret(_ value: Any?, maximumBytes: Int) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else { throw OAuthError.invalidResponse }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateSecret(trimmed, maximumBytes: maximumBytes)
        return trimmed
    }

    private static func pathIdentifier(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else { throw OAuthError.invalidResponse }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..", trimmed.utf8.count <= 256,
              trimmed.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                      || $0 == 45 || $0 == 46 || $0 == 95 || $0 == 126
              })
        else { throw OAuthError.invalidResponse }
        return trimmed
    }
}
