import Foundation

extension AccountIdentity {
    /// Provider responses and preferences are display-only, untrusted input.
    public func sanitized() -> Self? {
        let value = Self(
            email: Self.sanitizedEmail(email),
            name: Self.sanitizedText(name),
            plan: Self.sanitizedText(plan),
            organization: Self.sanitizedText(organization)
        )
        return value.isEmpty ? nil : value
    }

    static func sanitizedEmail(_ value: String?) -> String? {
        field(value, limit: 254)
    }

    static func sanitizedText(_ value: String?) -> String? {
        field(value, limit: 128)
    }

    private static func field(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.properties.generalCategory != .format && !CharacterSet.controlCharacters.contains($0)
        }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(limit)))
    }
}
