import Foundation
import Testing
@testable import QuotaCore

struct SubscriptionOAuthTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func pkceUsesS256Base64URLWithoutPadding() throws {
        let pkce = try OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(!pkce.challenge.contains("="))
    }

    @Test func claudeAuthorizationUsesCurrentClientCopyCodeRedirectAndScopes() throws {
        let pkce = try OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let state = "state-with-at-least-32-characters-123456789"
        let url = try ClaudeOAuth.authorizationURL(pkce: pkce, state: state)
        let query = queryItems(url)
        #expect(url.absoluteString.hasPrefix("https://claude.ai/oauth/authorize?"))
        #expect(query["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(query["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == state)
        #expect(query["scope"]?.contains("user:sessions:claude_code") == true)
    }

    @Test func claudeCodeInputRequiresMatchingState() throws {
        let state = "state-with-at-least-32-characters-123456789"
        let parsed = try ClaudeOAuth.parseAuthorizationInput("secret-code#\(state)", expectedState: state)
        #expect(parsed.code == "secret-code")
        #expect(parsed.state == state)
        let url = "https://platform.claude.com/oauth/code/callback?code=url-code&state=\(state)"
        #expect(try ClaudeOAuth.parseAuthorizationInput(url, expectedState: state).code == "url-code")
        #expect(throws: OAuthError.unauthorized) {
            _ = try ClaudeOAuth.parseAuthorizationInput("secret-code#wrong", expectedState: state)
        }
        #expect(throws: OAuthError.invalidResponse) {
            _ = try ClaudeOAuth.parseAuthorizationInput("secret-code", expectedState: state)
        }
    }

    @Test func claudeExchangeUsesJSONAndDecodesRotatingTokens() async throws {
        let transport = ScriptedOAuthTransport(responses: [
            .init(statusCode: 200, body: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8)),
        ])
        let pkce = try OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let tokens = try await ClaudeOAuth.exchange(
            code: "code", state: "state", pkce: pkce, transport: transport, now: now
        )
        #expect(tokens == OAuthTokens(
            accessToken: "access", refreshToken: "refresh", expiresAt: now.addingTimeInterval(3600)
        ))
        let request = await transport.onlyRequest()
        #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let object = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(object["grant_type"] == "authorization_code")
        #expect(object["code_verifier"] == pkce.verifier)
        #expect(object["redirect_uri"] == "https://platform.claude.com/oauth/code/callback")
    }

    @Test func codexAuthorizationAndRefreshMatchCLIContract() async throws {
        let pkce = try OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let state = "state-with-at-least-32-characters-123456789"
        let url = try CodexOAuth.authorizationURL(pkce: pkce, state: state)
        let query = queryItems(url)
        #expect(url.absoluteString.hasPrefix("https://auth.openai.com/oauth/authorize?"))
        #expect(query["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(query["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(query["scope"] == "openid profile email offline_access")
        #expect(query["id_token_add_organizations"] == "true")
        #expect(query["codex_cli_simplified_flow"] == "true")

        let jwt = makeJWT([
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-123"],
        ])
        let body = Data("{\"id_token\":\"\(jwt)\",\"access_token\":\"access\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600}".utf8)
        let transport = ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)])
        let tokens = try await CodexOAuth.refresh(refreshToken: "old refresh", transport: transport, now: now)
        #expect(tokens.accountID == "account-123")
        #expect(tokens.idToken == jwt)
        #expect(tokens.refreshToken == "new-refresh")
        let request = await transport.onlyRequest()
        #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(form.contains("grant_type=refresh_token"))
        #expect(form.contains("refresh_token=old+refresh"))
        #expect(form.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
    }

    @Test func codexRejectsTokenWithoutAccountID() async throws {
        let transport = ScriptedOAuthTransport(responses: [
            .init(statusCode: 200, body: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8)),
        ])
        await #expect(throws: OAuthError.invalidResponse) {
            _ = try await CodexOAuth.refresh(refreshToken: "refresh", transport: transport, now: now)
        }
    }

    @Test func codexDropsOversizedIDTokenWithoutFailingLogin() async throws {
        let access = makeJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "account-123"]])
        let body = try JSONSerialization.data(withJSONObject: [
            "id_token": String(repeating: "x", count: 16 * 1024 + 1),
            "access_token": access,
            "refresh_token": "refresh",
            "expires_in": 3600,
        ])
        let transport = ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)])
        let tokens = try await CodexOAuth.refresh(refreshToken: "old-refresh", transport: transport, now: now)
        #expect(tokens.accessToken == access)
        #expect(tokens.accountID == "account-123")
        #expect(tokens.idToken == nil)
    }

    @Test func codexRefreshKeepsPreviousIDTokenWhenAccountIsUnchanged() async throws {
        let idToken = makeJWT([
            "email": "user@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "account-123", "chatgpt_plan_type": "pro"],
        ])
        let access = makeJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "account-123"]])
        let previous = OAuthTokens(
            accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now.addingTimeInterval(3600),
            accountID: "account-123", idToken: idToken
        )
        let body = try JSONSerialization.data(withJSONObject: [
            "access_token": access, "refresh_token": "new-refresh", "expires_in": 7200,
        ])
        let transport = ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)])
        let refreshed = try await SubscriptionOAuthTokens.refresh(
            previous, provider: .codex, transport: transport, now: now
        )
        #expect(refreshed.idToken == idToken)
        #expect(refreshed.accountID == previous.accountID)
        #expect(refreshed.refreshToken == "new-refresh")
        #expect(CodexAccountIdentity.decode(tokens: refreshed)?.email == "user@example.com")
    }

    @Test func refreshWithoutRefreshTokenKeepsPreviousRefreshToken() async throws {
        let access = makeJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "account-123"]])
        for provider in [ProviderID.claude, .codex, .kimi] {
            let previous = OAuthTokens(
                accessToken: "old-access", refreshToken: "kept-refresh", expiresAt: now,
                accountID: provider == .codex ? "account-123" : nil
            )
            let body = try JSONSerialization.data(withJSONObject: ["access_token": access, "expires_in": 3600])
            let transport = ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)])
            let refreshed = try await SubscriptionOAuthTokens.refresh(previous, provider: provider, transport: transport, now: now)
            #expect(refreshed.accessToken == access)
            #expect(refreshed.refreshToken == "kept-refresh")
        }
    }

    @Test func signInWithoutRefreshTokenIsRejected() async throws {
        let body = Data(#"{"access_token":"access","expires_in":3600}"#.utf8)
        let pkce = try OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        await #expect(throws: OAuthError.invalidResponse) {
            _ = try await ClaudeOAuth.exchange(
                code: "code", state: "state", pkce: pkce,
                transport: ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)]), now: now
            )
        }
        await #expect(throws: OAuthError.invalidResponse) {
            _ = try await KimiOAuth.poll(
                device: device(), transport: ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)]),
                now: { now }
            ) { _ in }
        }
    }

    @Test func codexRefreshForAnotherAccountRequiresNewSignIn() async throws {
        let access = makeJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "account-456"]])
        let previous = OAuthTokens(
            accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now, accountID: "account-123"
        )
        let body = try JSONSerialization.data(withJSONObject: [
            "access_token": access, "refresh_token": "new-refresh", "expires_in": 3600,
        ])
        let transport = ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)])
        await #expect(throws: OAuthError.unauthorized) {
            _ = try await SubscriptionOAuthTokens.refresh(previous, provider: .codex, transport: transport, now: now)
        }
    }

    @Test func codexRefreshWithoutAccountIDKeepsPreviousAccount() async throws {
        let previous = OAuthTokens(
            accessToken: "old-access", refreshToken: "old-refresh", expiresAt: now, accountID: "account-123"
        )
        let body = Data(#"{"access_token":"opaque-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
        let transport = ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)])
        let refreshed = try await SubscriptionOAuthTokens.refresh(previous, provider: .codex, transport: transport, now: now)
        #expect(refreshed.accountID == "account-123")
        #expect(refreshed.refreshToken == "new-refresh")
    }

    @Test func tokenErrorsArePermanentOnlyForRevocationCodes() async throws {
        let cases: [(Int, String, OAuthError)] = [
            (400, #"{"error":{"message":"private detail","type":"invalid_request_error","code":"refresh_token_reused"}}"#, .unauthorized),
            (400, #"{"code":"refresh_token_expired"}"#, .unauthorized),
            (400, #"{"error":"invalid_grant"}"#, .unauthorized),
            (400, #"{"error":"invalid_client"}"#, .unauthorized),
            (400, #"{"error":"unauthorized_client"}"#, .unauthorized),
            (400, #"{"error":"unsupported_grant_type"}"#, .unauthorized),
            (400, #"{"error":"invalid_scope"}"#, .unauthorized),
            (401, "", .unauthorized),
            (403, "", .unauthorized),
            (400, #"{"error":"invalid_request"}"#, .unavailable),
            (400, #"{"error":{"message":"private detail","code":"invalid_request"}}"#, .unavailable),
            (429, "", .unavailable),
            (503, "", .unavailable),
        ]
        for (status, body, expected) in cases {
            let transport = ScriptedOAuthTransport(responses: [.init(statusCode: status, body: Data(body.utf8))])
            await #expect(throws: expected) {
                _ = try await CodexOAuth.refresh(refreshToken: "refresh", transport: transport, now: now)
            }
        }
    }

    @Test func tokenRequestsAreNotCutShortByTheTransport() async throws {
        let transport = try #require(SubscriptionOAuthTokens.defaultTransport() as? URLSessionRemoteUsageTransport)
        let scripted = ScriptedOAuthTransport(responses: [.init(statusCode: 503, body: Data())])
        _ = try? await KimiOAuth.refresh(refreshToken: "refresh", transport: scripted, now: now)
        let request = await scripted.onlyRequest()
        #expect(request.timeoutInterval == SubscriptionOAuthTokens.requestTimeout)
        #expect(transport.configuration.timeoutIntervalForResource >= request.timeoutInterval)
        #expect(transport.configuration.timeoutIntervalForRequest >= request.timeoutInterval)
    }

    @Test func kimiDeviceAuthorizationValidatesBrowserURLsAndDefaults() async throws {
        let body = Data(#"""
            {
              "device_code":"device","user_code":"ABCD-1234",
              "verification_uri":"https://www.kimi.com/code/device",
              "verification_uri_complete":"https://www.kimi.com/code/device?code=ABCD-1234",
              "interval":0,"expires_in":900
            }
        """#.utf8)
        let transport = ScriptedOAuthTransport(responses: [.init(statusCode: 200, body: body)])
        let device = try await KimiOAuth.startDeviceAuthorization(transport: transport)
        #expect(device.interval == 5)
        #expect(device.expiresIn == 900)
        #expect(device.userCode == "ABCD-1234")
        let request = await transport.onlyRequest()
        #expect(request.url?.absoluteString == "https://auth.kimi.com/api/oauth/device_authorization")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self) == "client_id=17e5f671-d194-4dfb-9706-5516cb48c098")
    }

    @Test func kimiPollingHandlesPendingSlowDownAndSuccess() async throws {
        let transport = ScriptedOAuthTransport(responses: [
            .init(statusCode: 400, body: Data(#"{"error":"authorization_pending"}"#.utf8)),
            .init(statusCode: 400, body: Data(#"{"error":"slow_down","interval":7}"#.utf8)),
            .init(statusCode: 200, body: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8)),
        ])
        let device = device(interval: 5, expiresIn: 60)
        let clock = ManualOAuthClock(now: now)
        let tokens = try await KimiOAuth.poll(device: device, transport: transport, now: clock.date) { seconds in
            clock.advance(seconds)
        }
        #expect(tokens.accessToken == "access")
        #expect(clock.sleeps == [5, 7])
    }

    @Test func kimiPollingRetriesTemporaryFailures() async throws {
        let transport = ScriptedOAuthTransport(responses: [
            .init(statusCode: 500, body: Data("server error".utf8)),
            .init(statusCode: 429, body: Data("rate limited".utf8)),
            .init(statusCode: nil, body: Data()),
            .init(statusCode: 200, body: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8)),
        ])
        let clock = ManualOAuthClock(now: now)

        let tokens = try await KimiOAuth.poll(device: device(interval: 5, expiresIn: 60), transport: transport, now: clock.date) { seconds in
            clock.advance(seconds)
        }

        #expect(tokens.accessToken == "access")
        #expect(clock.sleeps == [5, 5, 5])
    }

    @Test func kimiPollingMapsDenialExpiryAndTimeout() async throws {
        for (error, expected) in [("access_denied", OAuthError.denied), ("expired_token", .expired)] {
            let transport = ScriptedOAuthTransport(responses: [
                .init(statusCode: 400, body: Data("{\"error\":\"\(error)\"}".utf8)),
            ])
            await #expect(throws: expected) {
                _ = try await KimiOAuth.poll(device: device(), transport: transport, now: { now }) { _ in }
            }
        }

        let transport = ScriptedOAuthTransport(responses: [
            .init(statusCode: 400, body: Data(#"{"error":"authorization_pending"}"#.utf8)),
            .init(statusCode: 400, body: Data(#"{"error":"authorization_pending"}"#.utf8)),
            .init(statusCode: 400, body: Data(#"{"error":"authorization_pending"}"#.utf8)),
        ])
        let clock = ManualOAuthClock(now: now)
        await #expect(throws: OAuthError.timedOut) {
            _ = try await KimiOAuth.poll(
                device: device(interval: 1, expiresIn: 2), transport: transport,
                now: clock.date, sleep: clock.advance
            )
        }
        #expect(clock.sleeps == [1, 1])
    }

    @Test func kimiRefreshRejectsRevokedGrantWithoutEchoingServerBody() async throws {
        let transport = ScriptedOAuthTransport(responses: [
            .init(statusCode: 400, body: Data(#"{"error":"invalid_grant","error_description":"private detail"}"#.utf8)),
        ])
        await #expect(throws: OAuthError.unauthorized) {
            _ = try await KimiOAuth.refresh(refreshToken: "refresh", transport: transport, now: now)
        }
    }

    private func device(interval: TimeInterval = 5, expiresIn: TimeInterval = 60) -> KimiDeviceAuthorization {
        KimiDeviceAuthorization(
            deviceCode: "device", userCode: "code",
            verificationURL: URL(string: "https://www.kimi.com/code/device")!,
            verificationCompleteURL: URL(string: "https://www.kimi.com/code/device?code=code")!,
            interval: interval, expiresIn: expiresIn
        )
    }

    private func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func makeJWT(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJSUzI1NiJ9.\(encoded).signature"
    }
}

private actor ScriptedOAuthTransport: RemoteUsageTransport {
    private var responses: [RemoteUsageTransportResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [RemoteUsageTransportResponse]) { self.responses = responses }

    func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw QuotaError.unavailable }
        return responses.removeFirst()
    }

    func onlyRequest() -> URLRequest {
        precondition(requests.count == 1)
        return requests[0]
    }
}

private final class ManualOAuthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private(set) var sleeps: [TimeInterval] = []

    init(now: Date) { current = now }

    func date() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        sleeps.append(seconds)
        lock.unlock()
    }
}
