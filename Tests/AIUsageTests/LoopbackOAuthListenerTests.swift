import Testing
@testable import AIUsage

struct LoopbackOAuthListenerTests {
    private let state = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGH"

    @Test func acceptsOnlyTheRegisteredGETCallbackWithMatchingState() {
        #expect(LoopbackOAuthListener.parse(
            "GET /auth/callback?code=authorization-code&state=\(state) HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
            expectedState: state
        ) == .code("authorization-code"))

        for request in [
            "POST /auth/callback?code=authorization-code&state=\(state) HTTP/1.1",
            "GET /other?code=authorization-code&state=\(state) HTTP/1.1",
            "GET /auth/callback?code=authorization-code&state=wrong HTTP/1.1",
            "GET /auth/callback?code=one&code=two&state=\(state) HTTP/1.1",
            "GET /auth/callback?code=authorization-code&state=\(state)#fragment HTTP/1.1",
        ] {
            #expect(LoopbackOAuthListener.parse(request, expectedState: state) == .invalid)
        }
    }

    @Test func reportsProviderDenialWithoutAcceptingACode() {
        #expect(LoopbackOAuthListener.parse(
            "GET /auth/callback?error=access_denied&state=\(state) HTTP/1.1",
            expectedState: state
        ) == .denied)
    }
}
