import CryptoKit
import Foundation

public struct OAuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let accountID: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, accountID: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
    }

    public func validated() throws -> Self {
        guard expiresAt.timeIntervalSince1970.isFinite else { throw QuotaError.invalidResponse }
        try Self.validateSecret(accessToken)
        try Self.validateSecret(refreshToken)
        if let accountID {
            guard !accountID.isEmpty, accountID.count <= 1024,
                  accountID.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { throw QuotaError.invalidResponse }
        }
        return self
    }

    public func needsRefresh(at now: Date, leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }

    private static func validateSecret(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16 * 1024,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { throw QuotaError.invalidResponse }
    }
}

public enum OAuthError: Error, LocalizedError, Equatable, Sendable {
    case invalidResponse
    case unauthorized
    case denied
    case expired
    case timedOut
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The provider returned an invalid sign-in response."
        case .unauthorized: "The provider rejected the sign-in. Connect again."
        case .denied: "Sign-in was cancelled or denied."
        case .expired: "The sign-in code expired. Start again."
        case .timedOut: "Sign-in timed out. Start again."
        case .unavailable: "Cannot complete sign-in now. Try again later."
        }
    }
}

public struct OAuthPKCE: Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) throws {
        guard (43 ... 128).contains(verifier.count),
              verifier.utf8.allSatisfy({ Self.isUnreserved($0) })
        else { throw OAuthError.invalidResponse }
        self.verifier = verifier
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func generate() -> OAuthPKCE {
        let verifier = base64URL(Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }))
        // A 32-byte random value always produces a valid 43-character verifier.
        return try! OAuthPKCE(verifier: verifier)
    }

    public static func randomState() -> String {
        base64URL(Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
            || (48 ... 57).contains(byte) || byte == 45 || byte == 46 || byte == 95 || byte == 126
    }
}

public struct KimiDeviceAuthorization: Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let verificationCompleteURL: URL
    public let interval: TimeInterval
    public let expiresIn: TimeInterval

    public init(
        deviceCode: String,
        userCode: String,
        verificationURL: URL,
        verificationCompleteURL: URL,
        interval: TimeInterval,
        expiresIn: TimeInterval
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.verificationCompleteURL = verificationCompleteURL
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

private struct OAuthTokenPayload: Decodable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

private struct OAuthErrorPayload: Decodable {
    let error: String?
    let interval: Double?
}

private enum OAuthRequest {
    static func json(url: URL, fields: [String: String]) throws -> URLRequest {
        var request = base(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        } catch {
            throw OAuthError.invalidResponse
        }
        return request
    }

    static func form(url: URL, fields: [String: String]) -> URLRequest {
        var request = base(url: url)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncode(fields).utf8)
        return request
    }

    static func base(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    static func formEncode(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { key in
            "\(escape(key))=\(escape(fields[key] ?? ""))"
        }.joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case 65 ... 90, 97 ... 122, 48 ... 57, 45, 46, 95, 126:
                result.append(Character(UnicodeScalar(byte)))
            case 32:
                result.append("+")
            default:
                result.append(String(format: "%%%02X", byte))
            }
        }
        return result
    }
}

private func decodeToken(
    _ body: Data,
    provider: ProviderID,
    now: Date
) throws -> OAuthTokens {
    let payload: OAuthTokenPayload
    do {
        payload = try JSONDecoder().decode(OAuthTokenPayload.self, from: body)
    } catch {
        throw OAuthError.invalidResponse
    }
    let expiresIn: TimeInterval
    if let value = payload.expiresIn {
        guard value.isFinite, value > 0, value <= 10 * 366 * 86_400 else { throw OAuthError.invalidResponse }
        expiresIn = value
    } else if provider == .codex, let expiration = jwtExpiration(payload.accessToken) {
        expiresIn = expiration.timeIntervalSince(now)
        guard expiresIn > 0 else { throw OAuthError.invalidResponse }
    } else {
        throw OAuthError.invalidResponse
    }

    let accountID: String?
    if provider == .codex {
        accountID = payload.idToken.flatMap(chatGPTAccountID) ?? chatGPTAccountID(payload.accessToken)
        guard accountID != nil else { throw OAuthError.invalidResponse }
    } else {
        accountID = nil
    }

    do {
        return try OAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            accountID: accountID
        ).validated()
    } catch {
        throw OAuthError.invalidResponse
    }
}

private func checkTokenStatus(_ status: Int?, body: Data) throws {
    guard let status else { throw OAuthError.unavailable }
    if (200 ... 299).contains(status) { return }
    let payload = try? JSONDecoder().decode(OAuthErrorPayload.self, from: body)
    if status == 400 || status == 401 || status == 403 || payload?.error == "invalid_grant" {
        throw OAuthError.unauthorized
    }
    if status == 429 || status >= 500 { throw OAuthError.unavailable }
    throw OAuthError.unavailable
}

private func chatGPTAccountID(_ jwt: String) -> String? {
    guard let object = decodeJWT(jwt),
          let auth = object["https://api.openai.com/auth"] as? [String: Any],
          let value = auth["chatgpt_account_id"] as? String,
          !value.isEmpty, value.count <= 1024
    else { return nil }
    return value
}

private func jwtExpiration(_ jwt: String) -> Date? {
    guard let object = decodeJWT(jwt), let value = object["exp"] as? NSNumber else { return nil }
    let seconds = value.doubleValue
    guard seconds.isFinite, seconds > 0 else { return nil }
    return Date(timeIntervalSince1970: seconds)
}

private func decodeJWT(_ jwt: String) -> [String: Any]? {
    let pieces = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 3, !pieces[0].isEmpty, !pieces[1].isEmpty, !pieces[2].isEmpty,
          pieces[1].count <= 64 * 1024
    else { return nil }
    var encoded = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
    guard let data = Data(base64Encoded: encoded), data.count <= 64 * 1024,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
}

public enum ClaudeOAuth {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    private static let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    // Current omp Claude adapter: https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/auth/oauth/anthropic.ts
    public static func authorizationURL(pkce: OAuthPKCE, state: String) throws -> URL {
        guard state.count >= 32, state.count <= 128 else { throw OAuthError.invalidResponse }
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else { throw OAuthError.invalidResponse }
        return url
    }

    public static func parseAuthorizationInput(_ input: String, expectedState: String) throws -> (code: String, state: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16 * 1024 else { throw OAuthError.invalidResponse }
        var code: String?
        var state: String?
        if value.contains("#"), !value.contains("://") {
            let pieces = value.split(separator: "#", omittingEmptySubsequences: false)
            guard pieces.count == 2 else { throw OAuthError.invalidResponse }
            code = String(pieces[0])
            state = String(pieces[1])
        } else {
            let components: URLComponents?
            if value.contains("://") {
                components = URLComponents(string: value)
            } else if value.contains("code=") {
                components = URLComponents(string: "?\(value)")
            } else {
                components = nil
            }
            if let components {
                let items = components.queryItems ?? []
                code = items.first(where: { $0.name == "code" })?.value
                state = items.first(where: { $0.name == "state" })?.value
            }
        }
        guard let code, !code.isEmpty, code.utf8.count <= 4096,
              code.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let state, !state.isEmpty
        else { throw OAuthError.invalidResponse }
        guard state == expectedState else { throw OAuthError.unauthorized }
        return (code, state)
    }

    public static func exchange(
        code: String,
        state: String,
        pkce: OAuthPKCE,
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let request = try OAuthRequest.json(url: tokenURL, fields: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "code_verifier": pkce.verifier,
        ])
        let response = try await RemoteUsage.response(for: request, transport: transport)
        try checkTokenStatus(response.statusCode, body: response.body)
        return try decodeToken(response.body, provider: .claude, now: now)
    }

    public static func refresh(
        refreshToken: String,
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let request = try OAuthRequest.json(url: tokenURL, fields: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
        ])
        let response = try await RemoteUsage.response(for: request, transport: transport)
        try checkTokenStatus(response.statusCode, body: response.body)
        return try decodeToken(response.body, provider: .claude, now: now)
    }
}

public enum CodexOAuth {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let redirectURI = "http://localhost:1455/auth/callback"

    // Current omp and first-party Codex adapters:
    // https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/auth/oauth/openai-codex.ts
    // https://github.com/openai/codex/tree/main/codex-rs/login/src
    public static func authorizationURL(pkce: OAuthPKCE, state: String) throws -> URL {
        guard state.count >= 32, state.count <= 128 else { throw OAuthError.invalidResponse }
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "ai_usage"),
        ]
        guard let url = components?.url else { throw OAuthError.invalidResponse }
        return url
    }

    public static func exchange(
        code: String,
        pkce: OAuthPKCE,
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let request = OAuthRequest.form(url: tokenURL, fields: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "redirect_uri": redirectURI,
        ])
        let response = try await RemoteUsage.response(for: request, transport: transport)
        try checkTokenStatus(response.statusCode, body: response.body)
        return try decodeToken(response.body, provider: .codex, now: now)
    }

    public static func refresh(
        refreshToken: String,
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let request = OAuthRequest.form(url: tokenURL, fields: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
        ])
        let response = try await RemoteUsage.response(for: request, transport: transport)
        try checkTokenStatus(response.statusCode, body: response.body)
        return try decodeToken(response.body, provider: .codex, now: now)
    }
}

public enum KimiOAuth {
    private static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private static let deviceURL = URL(string: "https://auth.kimi.com/api/oauth/device_authorization")!
    private static let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    private static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

    // First-party implementation: https://github.com/MoonshotAI/kimi-cli/blob/main/src/kimi_cli/auth/oauth.py
    public static func startDeviceAuthorization(
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport()
    ) async throws -> KimiDeviceAuthorization {
        let request = OAuthRequest.form(url: deviceURL, fields: ["client_id": clientID])
        let response = try await RemoteUsage.response(for: request, transport: transport)
        try checkTokenStatus(response.statusCode, body: response.body)
        return try decodeDevice(response.body)
    }

    public static func poll(
        device: KimiDeviceAuthorization,
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport()
    ) async throws -> OAuthTokens {
        try await poll(device: device, transport: transport, now: Date.init) { seconds in
            try await Task.sleep(for: .milliseconds(max(1, Int(seconds * 1000))))
        }
    }

    static func poll(
        device: KimiDeviceAuthorization,
        transport: any RemoteUsageTransport,
        now: @escaping () -> Date,
        sleep: @escaping (TimeInterval) async throws -> Void
    ) async throws -> OAuthTokens {
        let startedAt = now()
        let deadline = startedAt.addingTimeInterval(device.expiresIn)
        var interval = device.interval

        while now() < deadline {
            try Task.checkCancellation()
            let request = OAuthRequest.form(url: tokenURL, fields: [
                "client_id": clientID,
                "device_code": device.deviceCode,
                "grant_type": deviceGrant,
            ])
            let response: RemoteUsageTransportResponse?
            do {
                response = try await RemoteUsage.response(for: request, transport: transport)
            } catch is CancellationError {
                throw CancellationError()
            } catch QuotaError.unavailable, QuotaError.rateLimited {
                response = nil
            }

            if let response {
                let payload = try? JSONDecoder().decode(OAuthErrorPayload.self, from: response.body)
                if let status = response.statusCode, (200 ... 299).contains(status) {
                    return try decodeToken(response.body, provider: .kimi, now: now())
                }
                switch payload?.error {
                case "authorization_pending":
                    break
                case "slow_down":
                    if let supplied = payload?.interval, supplied.isFinite, supplied > 0 {
                        interval = min(60, max(1, supplied))
                    } else {
                        interval = min(60, interval + 5)
                    }
                case "expired_token":
                    throw OAuthError.expired
                case "access_denied":
                    throw OAuthError.denied
                default:
                    if response.statusCode == 401 || response.statusCode == 403 {
                        throw OAuthError.unauthorized
                    }
                    if let status = response.statusCode, status != 429, status < 500 {
                        throw OAuthError.unavailable
                    }
                }
            }

            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { break }
            try await sleep(min(interval, remaining))
        }
        throw OAuthError.timedOut
    }

    public static func refresh(
        refreshToken: String,
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let request = OAuthRequest.form(url: tokenURL, fields: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        let response = try await RemoteUsage.response(for: request, transport: transport)
        try checkTokenStatus(response.statusCode, body: response.body)
        return try decodeToken(response.body, provider: .kimi, now: now)
    }

    private static func decodeDevice(_ body: Data) throws -> KimiDeviceAuthorization {
        struct Payload: Decodable {
            let deviceCode: String
            let userCode: String
            let verificationURI: String
            let verificationCompleteURI: String
            let expiresIn: Double?
            let interval: Double?

            enum CodingKeys: String, CodingKey {
                case deviceCode = "device_code"
                case userCode = "user_code"
                case verificationURI = "verification_uri"
                case verificationCompleteURI = "verification_uri_complete"
                case expiresIn = "expires_in"
                case interval
            }
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: body) }
        catch { throw OAuthError.invalidResponse }
        guard !payload.deviceCode.isEmpty, payload.deviceCode.utf8.count <= 4096,
              !payload.userCode.isEmpty, payload.userCode.utf8.count <= 256,
              let verification = trustedVerificationURL(payload.verificationURI),
              let complete = trustedVerificationURL(payload.verificationCompleteURI)
        else { throw OAuthError.invalidResponse }
        let expiresIn = payload.expiresIn.flatMap { $0.isFinite && $0 > 0 ? min($0, 15 * 60) : nil } ?? 15 * 60
        let interval = payload.interval.flatMap { $0.isFinite && $0 > 0 ? min(max($0, 1), 60) : nil } ?? 5
        return KimiDeviceAuthorization(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURL: verification,
            verificationCompleteURL: complete,
            interval: interval,
            expiresIn: expiresIn
        )
    }

    private static func trustedVerificationURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              ["auth.kimi.com", "www.kimi.com", "kimi.com"].contains(host),
              url.user == nil, url.password == nil
        else { return nil }
        return url
    }
}

public enum SubscriptionOAuthTokens {
    public static func refresh(
        _ tokens: OAuthTokens,
        provider: ProviderID,
        transport: any RemoteUsageTransport = RemoteUsage.defaultTransport(),
        now: Date = Date()
    ) async throws -> OAuthTokens {
        _ = try tokens.validated()
        switch provider {
        case .claude:
            return try await ClaudeOAuth.refresh(refreshToken: tokens.refreshToken, transport: transport, now: now)
        case .codex:
            return try await CodexOAuth.refresh(refreshToken: tokens.refreshToken, transport: transport, now: now)
        case .kimi:
            return try await KimiOAuth.refresh(refreshToken: tokens.refreshToken, transport: transport, now: now)
        default:
            throw OAuthError.unauthorized
        }
    }
}
