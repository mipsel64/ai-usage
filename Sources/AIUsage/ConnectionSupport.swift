import Foundation
import QuotaCore

@MainActor
func connectionStatus(state: ProviderState?) -> String {
    if state?.needsAuthentication == true { return "Access denied" }
    guard state?.connected == true else { return "Monitoring off" }
    return state?.snapshot == nil ? "Waiting for quota" : "Monitoring on"
}

extension Notification.Name {
    static let showProviderAccount = Notification.Name("AIUsage.ShowProviderAccount")
}

func connectionMessage(for error: Error) -> String {
    guard let quotaError = error as? QuotaError else {
        return error.localizedDescription
    }

    switch quotaError {
    case .notConfigured:
        return "Setup is incomplete. Check the connection details and try again."
    case .invalidResponse:
        return "The provider returned an unreadable response. Try again."
    case .unauthorized:
        return "The credentials were not accepted. Reconnect with valid credentials."
    case .rateLimited:
        return "The provider is rate limiting requests. Try again later."
    case .unavailable:
        return "The provider is unavailable. Try again later."
    }
}
