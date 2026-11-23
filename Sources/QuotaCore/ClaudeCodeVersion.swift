import Foundation

/// The Claude Code version that AI Usage reports to Claude. Claude lists limit resets only for a recent
/// version (it answers `ineligible_reason: "cli_version"` otherwise), so Preferences lets the user raise it.
public enum ClaudeCodeVersion {
    public static let defaultValue = "2.1.330"
    public static let defaultsKey = "claudeCodeVersion"

    /// Three dot-separated ASCII numbers, for example 2.1.330, so the value cannot change the User-Agent header.
    public static func isValid(_ text: String) -> Bool {
        text.wholeMatch(of: #/[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,5}/#) != nil
    }

    /// The stored version, or the default when no valid version is stored.
    public static func current(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey).flatMap { isValid($0) ? $0 : nil } ?? defaultValue
    }
}
