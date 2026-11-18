import QuotaCore
import SwiftUI

struct PendingReset {
    let provider: QuotaProvider
    let creditID: String
    let title: String?
    let expiry: Date?
}
