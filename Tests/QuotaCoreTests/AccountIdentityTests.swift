import Foundation
import Testing
@testable import QuotaCore

struct AccountIdentityTests {
    private let tokens = OAuthTokens(
        accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
        expiresAt: Date().addingTimeInterval(3600)
    )

    @Test func claudeDecodesAndSanitisesProfile() async throws {
        let body = Data(#"{"account":{"email":" user@example.com ","display_name":" Alice "},"organization":{"name":" Example Org ","plan_display_name":" Max "}}"#.utf8)
        let transport = AccountIdentityTransport(response: .init(statusCode: 200, body: body))
        let identity = try await ClaudeAccountIdentity.fetch(tokens: tokens, transport: transport)
        #expect(identity == AccountIdentity(email: "user@example.com", name: "Alice", plan: "Max", organization: "Example Org"))
        let request = await transport.onlyRequest()
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/profile")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test func claudeHandlesMissingHostileAndMalformedFields() {
        #expect(ClaudeAccountIdentity.decode(Data(#"{"account":{},"organization":{}}"#.utf8)) == nil)
        let hostile = ClaudeAccountIdentity.decode(Data("{\"account\":{\"email\":\" \(longString())\\u0000\",\"display_name\":\" A\\u0007lice \"}}".utf8))
        #expect(hostile?.email?.count == 254)
        #expect(hostile?.name == "Alice")
        #expect(hasNoControls(hostile))
        #expect(ClaudeAccountIdentity.decode(Data("not json".utf8)) == nil)
        #expect(ClaudeAccountIdentity.decode(Data(#"{"account":{"email":42}}"#.utf8)) == nil)
    }

    @Test func codexDecodesIDTokenAndExistingAccessToken() {
        let payload: [String: Any] = [
            "email": " user@example.com ",
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": " pro ",
                "organizations": [
                    ["title": "Other", "is_default": false],
                    ["title": " Example Org ", "is_default": true],
                ],
            ],
        ]
        let jwt = makeJWT(payload)
        #expect(CodexAccountIdentity.decode(jwt: jwt) == AccountIdentity(
            email: "user@example.com", plan: "pro", organization: "Example Org"
        ))
        var stored = tokens
        #expect(CodexAccountIdentity.decode(tokens: stored) == nil)
        stored = OAuthTokens(
            accessToken: jwt, refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)
        )
        #expect(CodexAccountIdentity.decode(tokens: stored)?.email == "user@example.com")
        stored = OAuthTokens(
            accessToken: "opaque", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600), idToken: jwt
        )
        #expect(CodexAccountIdentity.decode(tokens: stored)?.plan == "pro")
    }

    @Test func codexHandlesMissingHostileAndMalformedClaims() {
        #expect(CodexAccountIdentity.decode(jwt: makeJWT(["sub": "user"])) == nil)
        let hostile = CodexAccountIdentity.decode(jwt: makeJWT([
            "email": longString(),
            "https://api.openai.com/auth": ["chatgpt_plan_type": " p\u{0000}ro "],
        ]))
        #expect(hostile?.email?.count == 254)
        #expect(hostile?.plan == "pro")
        #expect(hasNoControls(hostile))
        #expect(CodexAccountIdentity.decode(jwt: "not-a-jwt") == nil)
        #expect(CodexAccountIdentity.decode(jwt: makeJWT(["email": 42])) == nil)
    }

    @Test func kimiDecodesAndSanitisesManagedProfile() async throws {
        let body = Data(#"{"user_id":"user-1","email":" user@example.com ","nickname":" Alice "}"#.utf8)
        let transport = AccountIdentityTransport(response: .init(statusCode: 200, body: body))
        let identity = try await KimiAccountIdentity.fetch(tokens: tokens, transport: transport)
        #expect(identity == AccountIdentity(email: "user@example.com", name: "Alice"))
        let request = await transport.onlyRequest()
        #expect(request.url?.absoluteString == "https://api.kimi.com/coding/v1/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
    }

    @Test func kimiHandlesMissingHostileAndMalformedFields() {
        #expect(KimiAccountIdentity.decode(Data(#"{"user_id":"user-1"}"#.utf8)) == nil)
        let hostile = KimiAccountIdentity.decode(Data("{\"user_id\":\"user-1\",\"email\":\"\(longString())\",\"nickname\":\" A\\u0007lice \"}".utf8))
        #expect(hostile?.email?.count == 254)
        #expect(hostile?.name == "Alice")
        #expect(hasNoControls(hostile))
        #expect(KimiAccountIdentity.decode(Data("not json".utf8)) == nil)
        #expect(KimiAccountIdentity.decode(Data(#"{"email":"user@example.com"}"#.utf8)) == nil)
    }

    @Test func zaiDecodesSignInUserAndSelectedOrganization() {
        let identity = ZaiAccountIdentity.decode(
            user: ["email": " user@example.com ", "name": " Alice "],
            organization: ["organizationName": " Example Org "]
        )
        #expect(identity == AccountIdentity(email: "user@example.com", name: "Alice", organization: "Example Org"))
    }

    @Test func zaiHandlesMissingHostileAndMalformedFields() {
        #expect(ZaiAccountIdentity.decode(user: ["user_id": "user-1"], organization: nil) == nil)
        let hostile = ZaiAccountIdentity.decode(
            user: ["email": longString(), "name": " A\u{0007}lice "],
            organization: ["organizationName": longString()]
        )
        #expect(hostile?.email?.count == 254)
        #expect(hostile?.name == "Alice")
        #expect(hostile?.organization?.count == 128)
        #expect(hasNoControls(hostile))
        #expect(ZaiAccountIdentity.decode(user: ["email": 42], organization: ["organizationName": false]) == nil)
    }

    @Test func emptySanitisedIdentityIsNilAndFormatCharactersAreRemoved() {
        #expect(AccountIdentity(email: " \n ", name: "\u{0000}").sanitized() == nil)
        #expect(AccountIdentity(name: "A\u{202E}B").sanitized()?.name == "AB")
    }

    private func longString() -> String { String(repeating: "x", count: 300) }

    private func hasNoControls(_ identity: AccountIdentity?) -> Bool {
        [identity?.email, identity?.name, identity?.plan, identity?.organization].compactMap { $0 }.allSatisfy {
            $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
    }

    private func makeJWT(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "synthetic-header.\(encoded).synthetic-signature"
    }
}

private actor AccountIdentityTransport: RemoteUsageTransport {
    private let response: RemoteUsageTransportResponse
    private var requests: [URLRequest] = []
    init(response: RemoteUsageTransportResponse) { self.response = response }
    func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse {
        requests.append(request)
        return response
    }
    func onlyRequest() -> URLRequest { requests[0] }
}
