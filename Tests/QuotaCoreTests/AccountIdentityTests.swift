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
        let fallback = ClaudeAccountIdentity.decode(Data(#"{"account":{"display_name":" \u0000 ","full_name":" Fallback Name "},"organization":{"plan_display_name":" \u0000 ","organization_type":" claude_pro "}}"#.utf8))
        #expect(fallback == AccountIdentity(name: "Fallback Name", plan: "claude_pro"))
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
            "name": " Alice ",
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
            email: "user@example.com", name: "Alice", plan: "pro", organization: "Example Org"
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

    @Test func codexMergesIDAndAccessTokenIdentityByField() {
        let idToken = makeJWT([
            "name": " ID Name ",
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "pro",
                "organizations": [["title": "Workspace", "is_default": true]],
            ],
        ])
        let accessToken = makeJWT([
            "email": " access@example.com ",
            "name": "Access Name",
            "https://api.openai.com/auth": [
                "chatgpt_plan_type": "plus",
            ],
        ])
        let merged = CodexAccountIdentity.decode(tokens: OAuthTokens(
            accessToken: accessToken, refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), accountID: "selected", idToken: idToken
        ))
        #expect(merged == AccountIdentity(
            email: "access@example.com", name: "Access Name", plan: "plus", organization: "Workspace"
        ))
    }

    @Test(arguments: [false, true])
    func codexIgnoresTokenFromDifferentAccount(mismatchedAccessToken: Bool) {
        let different = makeJWT([
            "email": "different@example.com",
            "https://api.openai.com/auth": ["chatgpt_account_id": "different", "chatgpt_plan_type": "pro"],
        ])
        let selected = makeJWT([
            "https://api.openai.com/auth": ["chatgpt_account_id": "selected", "chatgpt_plan_type": "plus"],
        ])
        let identity = CodexAccountIdentity.decode(tokens: OAuthTokens(
            accessToken: mismatchedAccessToken ? different : selected, refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), accountID: "selected",
            idToken: mismatchedAccessToken ? selected : different
        ))
        #expect(identity == AccountIdentity(plan: "plus"))
    }

    @Test func codexIgnoresTokenWithMalformedAccountID() {
        let accessToken = makeJWT([
            "https://api.openai.com/auth": ["chatgpt_account_id": 42, "chatgpt_plan_type": "pro"],
        ])
        let identity = CodexAccountIdentity.decode(tokens: OAuthTokens(
            accessToken: accessToken, refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), accountID: "selected"
        ))
        #expect(identity == nil)
    }

    @Test func codexHandlesMissingHostileAndMalformedClaims() {
        #expect(CodexAccountIdentity.decode(jwt: makeJWT(["sub": "user"])) == nil)
        let fallback = CodexAccountIdentity.decode(jwt: makeJWT([
            "email": "\u{200B} \u{200B}",
            "https://api.openai.com/profile": ["email": " profile@example.com "],
        ]))
        #expect(fallback?.email == "profile@example.com")
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

    @Test func codexReadsSubscriptionActiveUntilClaim() throws {
        func periodEnd(_ value: Any) -> Date? {
            CodexAccountIdentity.decode(jwt: makeJWT([
                "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_subscription_active_until": value],
            ]))?.periodEnd
        }
        #expect(periodEnd("2030-07-29T12:09:00Z") == Date(timeIntervalSince1970: 1_911_557_340))
        let fractional = try #require(periodEnd("2030-07-29T12:09:00.284171+00:00"))
        #expect(abs(fractional.timeIntervalSince1970 - 1_911_557_340.284) < 0.001)
        #expect(CodexAccountIdentity.decode(jwt: makeJWT([
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ])) == AccountIdentity(plan: "plus"))
        #expect(periodEnd("2030-07-29") == nil)
        #expect(periodEnd("next month") == nil)
        #expect(periodEnd(1_911_557_340) == nil)
        #expect(periodEnd("2019-12-31T23:59:59Z") == nil)
        #expect(periodEnd("2090-01-01T00:00:00Z") == nil)
        #expect(CodexAccountIdentity.decode(jwt: makeJWT([
            "https://api.openai.com/auth": ["chatgpt_subscription_active_until": "1970-01-01T00:00:00Z"],
        ])) == nil)
    }

    @Test func codexTakesPeriodEndFromIDTokenWhenAccessTokenLacksIt() {
        let accessToken = makeJWT(["https://api.openai.com/auth": ["chatgpt_plan_type": "plus"]])
        let idToken = makeJWT(["https://api.openai.com/auth": ["chatgpt_subscription_active_until": "2030-07-29T12:09:00Z"]])
        let identity = CodexAccountIdentity.decode(tokens: OAuthTokens(
            accessToken: accessToken, refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), idToken: idToken
        ))
        #expect(identity == AccountIdentity(plan: "plus", periodEnd: Date(timeIntervalSince1970: 1_911_557_340)))
    }

    @Test func zaiFetchesSubscriptionListWithTheSubscriptionKey() async throws {
        let transport = AccountIdentityTransport(response: .init(statusCode: 200, body: zaiList(#"{"productName":"GLM Coding Max","status":"VALID","inCurrentPeriod":true,"autoRenew":1,"nextRenewTime":"2030-03-12"}"#)))
        let identity = try await ZaiAccountIdentity.fetchSubscription(key: "synthetic-key", transport: transport)
        #expect(identity == AccountIdentity(periodEnd: localMidnight(2030, 3, 12), renews: true))
        let request = await transport.onlyRequest()
        #expect(request.url?.absoluteString == "https://api.z.ai/api/biz/subscription/list")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-key")
    }

    @Test func zaiReadsRenewalOfTheActiveCodingPlan() {
        func plan(_ fields: String) -> AccountIdentity? {
            ZaiAccountIdentity.decodeSubscription(zaiList(
                #"{"productName":"GLM Coding Pro","status":"VALID","inCurrentPeriod":true,"# + fields + "}"
            ))
        }
        #expect(plan(#""autoRenew":true,"nextRenewTime":"2030-03-12""#)?.renews == true)
        #expect(plan(#""autoRenew":0,"nextRenewTime":"2030-03-12""#) == AccountIdentity(periodEnd: localMidnight(2030, 3, 12), renews: false))
        #expect(plan(#""autoRenew":false,"nextRenewTime":"2030-03-12""#)?.renews == false)
        #expect(plan(#""nextRenewTime":"2030-03-12""#) == AccountIdentity(periodEnd: localMidnight(2030, 3, 12)))
        #expect(plan(#""autoRenew":"yes","nextRenewTime":"2030-03-12""#)?.renews == nil)
        #expect(plan(#""autoRenew":1,"nextRenewTime":"2030-03-12 16:55:13""#)?.periodEnd == Date(timeIntervalSince1970: 1_899_536_113))
        #expect(plan(#""autoRenew":1"#) == nil)
        #expect(plan(#""autoRenew":1,"nextRenewTime":"2030-02-30""#) == nil)
        #expect(plan(#""autoRenew":1,"nextRenewTime":"soon""#) == nil)
        #expect(plan(#""autoRenew":1,"nextRenewTime":1899536113"#) == nil)
        #expect(plan(#""autoRenew":1,"nextRenewTime":"2030-03-12T16:55:13""#) == nil)
        #expect(plan(#""autoRenew":1,"nextRenewTime":"2019-12-31""#) == nil)
        #expect(plan(#""autoRenew":1,"nextRenewTime":"2090-01-01""#) == nil)
    }

    @Test func zaiSkipsUnrelatedEntriesAndRejectsFailedEnvelopes() {
        let active = #"{"productId":"coding-pro","status":"VALID","inCurrentPeriod":true,"autoRenew":1,"nextRenewTime":"2030-03-12"}"#
        let unrelated = [
            #""text""#,
            #"{"productName":"GLM Search","status":"VALID","inCurrentPeriod":true,"nextRenewTime":"2030-01-01"}"#,
            #"{"productName":"GLM Coding Lite","status":"EXPIRED","inCurrentPeriod":true,"nextRenewTime":"2030-01-02"}"#,
            #"{"productName":"GLM Coding Lite","status":"VALID","inCurrentPeriod":false,"nextRenewTime":"2030-01-03"}"#,
        ].joined(separator: ",")
        #expect(ZaiAccountIdentity.decodeSubscription(zaiList(unrelated + "," + active))?.periodEnd == localMidnight(2030, 3, 12))
        #expect(ZaiAccountIdentity.decodeSubscription(zaiList(unrelated)) == nil)
        #expect(ZaiAccountIdentity.decodeSubscription(zaiList("")) == nil)
        #expect(ZaiAccountIdentity.decodeSubscription(Data(#"{"code":500,"data":[\#(active)]}"#.utf8)) == nil)
        #expect(ZaiAccountIdentity.decodeSubscription(Data(#"{"success":false,"data":[\#(active)]}"#.utf8)) == nil)
        #expect(ZaiAccountIdentity.decodeSubscription(Data(#"{"data":[\#(active)]}"#.utf8))?.renews == true)
        #expect(ZaiAccountIdentity.decodeSubscription(Data(#"{"code":200,"data":{}}"#.utf8)) == nil)
        #expect(ZaiAccountIdentity.decodeSubscription(Data("not json".utf8)) == nil)
    }

    @Test func storedIdentityWithoutPeriodStillDecodes() throws {
        let old = try JSONDecoder().decode(AccountIdentity.self, from: Data(#"{"email":"user@example.com","plan":"pro"}"#.utf8))
        #expect(old == AccountIdentity(email: "user@example.com", plan: "pro"))
        let current = AccountIdentity(plan: "pro", periodEnd: Date(timeIntervalSince1970: 1_911_557_340), renews: false)
        #expect(try JSONDecoder().decode(AccountIdentity.self, from: JSONEncoder().encode(current)) == current)
    }

    @Test func sanitizingKeepsAPlausiblePeriodAndDropsRenewalWithoutIt() {
        let periodEnd = Date().addingTimeInterval(86_400)
        #expect(AccountIdentity(periodEnd: periodEnd, renews: true).sanitized() == AccountIdentity(periodEnd: periodEnd, renews: true))
        #expect(AccountIdentity(renews: true).sanitized() == nil)
        #expect(AccountIdentity(name: "Alice", periodEnd: Date(timeIntervalSince1970: 0), renews: true).sanitized()
            == AccountIdentity(name: "Alice"))
    }

    private func zaiList(_ items: String) -> Data {
        Data((#"{"code":200,"msg":"ok","success":true,"data":["# + items + "]}").utf8)
    }

    private func localMidnight(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
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
        #expect(KimiAccountIdentity.decode(Data(#"{"user_id":"   ","email":"user@example.com"}"#.utf8)) == nil)
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
        #expect(AccountIdentity(name: "\u{200B} \u{200B}").sanitized() == nil)
        let combining = "a" + String(repeating: "\u{0301}", count: 200)
        #expect(AccountIdentity(name: combining).sanitized()?.name?.unicodeScalars.count == 128)
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
