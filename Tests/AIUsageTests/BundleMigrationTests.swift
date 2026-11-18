import Foundation
import Testing
@testable import AIUsage

struct PreferencesMigrationTests {
    @Test func bundleIdentifierMigrationPreservesOnlyAppSettingsOnce() throws {
        let legacySuite = "LegacyPreferences.\(UUID().uuidString)"
        let currentSuite = "CurrentPreferences.\(UUID().uuidString)"
        let legacy = try #require(UserDefaults(suiteName: legacySuite))
        let current = try #require(UserDefaults(suiteName: currentSuite))
        defer {
            legacy.removePersistentDomain(forName: legacySuite)
            current.removePersistentDomain(forName: currentSuite)
        }
        legacy.set(true, forKey: "notify")
        legacy.set(true, forKey: "connected.claude")
        legacy.set(1, forKey: "oauthVersion.claude")
        legacy.set("do not copy", forKey: "unrelated")

        PreferencesMigration.migrate(from: legacy, into: current)
        legacy.set(false, forKey: "connected.claude")
        PreferencesMigration.migrate(from: legacy, into: current)

        #expect(current.bool(forKey: "notify"))
        #expect(current.bool(forKey: "connected.claude"))
        #expect(current.integer(forKey: "oauthVersion.claude") == 1)
        #expect(current.string(forKey: "unrelated") == nil)
    }
}

@MainActor
struct ZaiCallbackRouterTests {
    @Test func callbackArrivingBeforeDialogIsBuffered() {
        let router = ZaiCallbackRouter()
        let url = URL(string: "zcode://zai-auth/callback?code=code&state=state")!
        router.receive(url)
        var received: URL?

        router.listen { received = $0 }

        #expect(received == url)
        router.reset()
        received = nil
        router.listen { received = $0 }
        #expect(received == nil)
    }
}
