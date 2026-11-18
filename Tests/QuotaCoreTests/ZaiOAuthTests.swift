import Foundation
import Testing
@testable import QuotaCore

struct ZaiOAuthTests {
    private let state = "state-with-at-least-32-characters-123456789"
    private let keysURL = "https://api.z.ai/api/biz/v1/organization/org-1/projects/proj-1/api_keys"

    @Test func authorizationUsesZCodeCallbackWithoutPKCE() throws {
        let url = try ZaiOAuth.authorizationURL(state: state)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.absoluteString.hasPrefix("https://chat.z.ai/api/oauth/authorize?"))
        #expect(items["client_id"] == "client_P8X5CMWmlaRO9gyO-KSqtg")
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == "zcode://zai-auth/callback")
        #expect(items["state"] == state)
        #expect(items["code_challenge"] == nil)
        #expect(items["code_challenge_method"] == nil)
    }

    @Test func pastedCodeAndFinalURLRequireExactCallbackAndState() throws {
        #expect(try ZaiOAuth.parseAuthorizationInput(" auth-code#\(state) ", expectedState: state).code == "auth-code")
        let finalURL = "zcode://zai-auth/callback?code=url-code&state=\(state)"
        #expect(try ZaiOAuth.parseAuthorizationInput(finalURL, expectedState: state).code == "url-code")
        #expect(throws: OAuthError.unauthorized) {
            _ = try ZaiOAuth.parseAuthorizationInput("auth-code#wrong", expectedState: state)
        }
        #expect(throws: OAuthError.invalidResponse) {
            _ = try ZaiOAuth.parseAuthorizationInput("https://zai-auth/callback?code=url-code&state=\(state)", expectedState: state)
        }
        #expect(throws: OAuthError.invalidResponse) {
            _ = try ZaiOAuth.parseAuthorizationInput("auth-code", expectedState: state)
        }
        #expect(throws: OAuthError.denied) {
            _ = try ZaiOAuth.parseAuthorizationInput("zcode://zai-auth/callback?error=access_denied&state=\(state)", expectedState: state)
        }
    }

    @Test func exchangeCreatesAndCopiesOnlyTheDurableMintedKey() async throws {
        let transport = ZaiScriptedTransport(responses: createResponses())
        let key = try await ZaiOAuth.exchange(code: "auth-code", state: state, transport: transport)
        #expect(key == "created-key.real-secret")
        let requests = await transport.requests
        #expect(requests.map(\.url?.absoluteString) == [
            "https://zcode.z.ai/api/v1/oauth/token",
            "https://api.z.ai/api/auth/z/login",
            "https://api.z.ai/api/biz/customer/getCustomerInfo",
            keysURL,
            keysURL,
            "\(keysURL)/copy/created-key",
        ])
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "GET", "GET", "POST", "GET"])
        let tokenBody = try jsonObject(requests[0])
        #expect(tokenBody["provider"] as? String == "zai")
        #expect(tokenBody["code"] as? String == "auth-code")
        #expect(tokenBody["redirect_uri"] as? String == "zcode://zai-auth/callback")
        #expect(tokenBody["state"] as? String == state)
        #expect(try jsonObject(requests[1])["token"] as? String == "oauth-access-token")
        #expect(try jsonObject(requests[4])["name"] as? String == "AI Usage")
        for request in requests.dropFirst(2) {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer biz-token")
        }
    }

    @Test func exchangeReusesNamedKeyAndIgnoresMaskedAndInlineSecrets() async throws {
        var responses = createResponses()
        responses[3] = .json(#"{"code":200,"success":true,"data":[{"name":"zcode-api-key","apiKey":"zcode-key"},{"name":"AI Usage","apiKey":"existing-key","secretKey":"*****masked"}]}"#)
        responses.remove(at: 4)
        responses[4] = .json(#"{"code":200,"success":true,"data":{"secretKey":"copied-secret"}}"#)
        let transport = ZaiScriptedTransport(responses: responses)
        let key = try await ZaiOAuth.exchange(code: "auth-code", state: state, transport: transport)
        #expect(key == "existing-key.copied-secret")
        let requests = await transport.requests
        #expect(requests.count == 5)
        #expect(requests.last?.url?.absoluteString == "\(keysURL)/copy/existing-key")
    }

    @Test func providerErrorsAreStaticAndNeverEchoResponseSecrets() async throws {
        var responses = createResponses()
        responses[0] = .json(#"{"code":1,"msg":"private token rejected secret-value"}"#)
        let tokenFailure = ZaiScriptedTransport(responses: responses)
        await #expect(throws: OAuthError.unauthorized) {
            _ = try await ZaiOAuth.exchange(code: "auth-code", state: state, transport: tokenFailure)
        }

        responses = createResponses()
        responses[1] = .json(#"{"code":401,"success":false,"msg":"private business detail"}"#)
        let businessFailure = ZaiScriptedTransport(responses: responses)
        await #expect(throws: OAuthError.unauthorized) {
            _ = try await ZaiOAuth.exchange(code: "auth-code", state: state, transport: businessFailure)
        }
    }

    @Test func malformedAndOversizedResponsesAreRejected() async throws {
        var responses = createResponses()
        responses[2] = .json(#"{"code":200,"success":true,"data":{"organizations":[]}}"#)
        let missingCustomer = ZaiScriptedTransport(responses: responses)
        await #expect(throws: OAuthError.invalidResponse) {
            _ = try await ZaiOAuth.exchange(code: "auth-code", state: state, transport: missingCustomer)
        }

        let oversized = ZaiScriptedTransport(responses: [
            RemoteUsageTransportResponse(statusCode: 200, body: Data(repeating: 32, count: RemoteUsage.maximumResponseBytes + 1)),
        ])
        await #expect(throws: OAuthError.invalidResponse) {
            _ = try await ZaiOAuth.exchange(code: "auth-code", state: state, transport: oversized)
        }
    }

    private func createResponses() -> [RemoteUsageTransportResponse] {
        [
            .json(#"{"code":0,"msg":"ok","data":{"token":"discarded-zcode-jwt","zai":{"access_token":"oauth-access-token"},"user":{"id":"user-42"}}}"#),
            .json(#"{"code":200,"success":true,"data":{"access_token":"biz-token","expires_in":3600}}"#),
            .json(#"{"code":200,"success":true,"data":{"organizations":[{"organizationId":"org-other","projects":[{"projectId":"proj-x"}]},{"organizationId":"org-1","isDefault":true,"projects":[{"projectId":"proj-a"},{"projectId":"proj-1","isDefault":true}]}]}}"#),
            .json(#"{"code":200,"success":true,"data":[]}"#),
            .json(#"{"code":200,"success":true,"data":{"name":"AI Usage","apiKey":"created-key","secretKey":"inline-ignored"}}"#),
            .json(#"{"code":200,"success":true,"data":{"secretKey":"real-secret"}}"#),
        ]
    }

    private func jsonObject(_ request: URLRequest) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }
}

private actor ZaiScriptedTransport: RemoteUsageTransport {
    private var responses: [RemoteUsageTransportResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [RemoteUsageTransportResponse]) { self.responses = responses }

    func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw QuotaError.unavailable }
        return responses.removeFirst()
    }
}

private extension RemoteUsageTransportResponse {
    static func json(_ string: String) -> Self {
        Self(statusCode: 200, body: Data(string.utf8))
    }
}
