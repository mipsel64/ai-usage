import Foundation

extension AccountIdentity {
    /// Provider responses and preferences are display-only, untrusted input.
    public func sanitized() -> Self? {
        let periodEnd = Self.plausible(periodEnd)
        let value = Self(
            email: Self.sanitizedEmail(email),
            name: Self.sanitizedText(name),
            plan: Self.sanitizedText(plan),
            organization: Self.sanitizedText(organization),
            periodEnd: periodEnd,
            renews: periodEnd == nil ? nil : renews
        )
        return value.isEmpty ? nil : value
    }

    private static let earliestPeriodEnd = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01T00:00:00Z

    /// Drops a date that a unit or format mistake would produce.
    private static func plausible(_ date: Date?) -> Date? {
        guard let date, date >= earliestPeriodEnd,
              date <= Calendar(identifier: .gregorian).date(byAdding: .year, value: 20, to: Date())!
        else { return nil }
        return date
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
