import Foundation
import QuotaCore

struct PendingReset {
    let provider: QuotaProvider
    let option: ResetOption
    /// The connection that the user confirmed for; see `UsageStore.connection(_:)`.
    let connection: UUID?
}
