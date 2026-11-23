import Foundation
import Testing
@testable import QuotaCore

struct ClaudeCodeVersionTests {
    @Test(arguments: ["2.1.330", "0.0.0", "9999.9999.99999"])
    func acceptsThreeNumbers(version: String) {
        #expect(ClaudeCodeVersion.isValid(version))
    }

    @Test(arguments: [
        "", "2.1", "2.1.330.1", "v2.1.330", "2.1.330 ", " 2.1.330", "2.1.330\r\nX-Injected: 1",
        "2.1.x", "10000.1.1", "1.1.100000", "٢.١.٣٣٠", "２.1.330",
    ])
    func rejectsOtherText(version: String) {
        #expect(!ClaudeCodeVersion.isValid(version))
    }

    @Test func readsStoredVersionAndFallsBackToTheDefault() throws {
        try withDefaults { defaults in
            #expect(ClaudeCodeVersion.current(in: defaults) == "2.1.330")
            defaults.set("2.1.400", forKey: ClaudeCodeVersion.defaultsKey)
            #expect(ClaudeCodeVersion.current(in: defaults) == "2.1.400")
            defaults.set("2.1.400\r\nX: 1", forKey: ClaudeCodeVersion.defaultsKey)
            #expect(ClaudeCodeVersion.current(in: defaults) == "2.1.330")
            defaults.set(5, forKey: ClaudeCodeVersion.defaultsKey)
            #expect(ClaudeCodeVersion.current(in: defaults) == "2.1.330")
            defaults.set(["2.1.400"], forKey: ClaudeCodeVersion.defaultsKey)
            #expect(ClaudeCodeVersion.current(in: defaults) == "2.1.330")
        }
    }

    @Test func storesOnlyValidVersionsAndRemovesTheKeyForTheDefault() throws {
        try withDefaults { defaults in
            #expect(ClaudeCodeVersion.store("2.1.400", in: defaults))
            #expect(defaults.string(forKey: ClaudeCodeVersion.defaultsKey) == "2.1.400")
            #expect(!ClaudeCodeVersion.store("2.1", in: defaults))
            #expect(!ClaudeCodeVersion.store("2.1.500\r\nX: 1", in: defaults))
            #expect(defaults.string(forKey: ClaudeCodeVersion.defaultsKey) == "2.1.400")
            #expect(ClaudeCodeVersion.store("2.1.330", in: defaults))
            #expect(defaults.object(forKey: ClaudeCodeVersion.defaultsKey) == nil)
        }
    }

    @Test(arguments: [("2.1.400", "2.1.400"), ("2.1.400\r\nX: 1", "2.1.330"), ("", "2.1.330")])
    func claudeReadSendsTheStoredVersion(stored: String, sent: String) async throws {
        let suite = "ClaudeCodeVersionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(stored, forKey: ClaudeCodeVersion.defaultsKey)
        let transport = VersionTransport()

        _ = try await ClaudeRemoteUsage.fetch(tokens: Self.tokens, transport: transport, defaults: defaults)

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/\(sent) (external, cli)")
    }

    @Test func claudeRequestRefusesAnInvalidVersion() {
        #expect(throws: QuotaError.notConfigured) {
            _ = try ClaudeRemoteUsage.request(tokens: Self.tokens, cliVersion: "2.1.400\r\nX: 1")
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ClaudeCodeVersionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private static let tokens = OAuthTokens(accessToken: "claude-access", refreshToken: "claude-refresh", expiresAt: Date().addingTimeInterval(3600))
}

private actor VersionTransport: RemoteUsageTransport {
    private(set) var requests: [URLRequest] = []

    func response(for request: URLRequest) async throws -> RemoteUsageTransportResponse {
        requests.append(request)
        return .init(statusCode: 200, body: Data(#"{"seven_day":{"utilization":15,"resets_at":null}}"#.utf8))
    }
}
