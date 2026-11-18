import Foundation

extension AccountIdentity {
    /// Provider responses and preferences are display-only, untrusted input.
    public func sanitized() -> Self? {
        let value = Self(
            email: Self.field(email, limit: 254),
            name: Self.field(name, limit: 128),
            plan: Self.field(plan, limit: 128),
            organization: Self.field(organization, limit: 128)
        )
        return value.isEmpty ? nil : value
    }

    private static func field(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter {
            $0.properties.generalCategory != .format && !CharacterSet.controlCharacters.contains($0)
        }))
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(limit))
    }
}
