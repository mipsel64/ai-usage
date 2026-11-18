import Foundation

enum PreferencesMigration {
    private static let legacySuite = "app.aiusage.menubar"
    private static let marker = "preferences.migratedBundleIdentifier"

    static func migrateIfNeeded(into defaults: UserDefaults) {
        guard defaults === UserDefaults.standard,
              Bundle.main.bundleIdentifier == "com.mipsel64.aiusage",
              let legacy = UserDefaults(suiteName: legacySuite)
        else { return }
        migrate(from: legacy, into: defaults)
    }

    static func migrate(from legacy: UserDefaults, into defaults: UserDefaults) {
        guard !defaults.bool(forKey: marker) else { return }
        let prefixes = ["connected.", "path.", "snapshot.", "oauthVersion.", "intent.", "account."]
        for (key, value) in legacy.dictionaryRepresentation()
        where key == "notify" || prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: marker)
    }
}
