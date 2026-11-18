import QuotaCore

enum AccountSelection: Hashable {
    case provider(ProviderID)
    case notifications
}
