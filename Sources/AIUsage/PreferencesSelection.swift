import QuotaCore

enum PreferencesSelection: Hashable {
    case provider(ProviderID)
    case general
    case notifications
    case about
}
