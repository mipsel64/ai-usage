import QuotaCore
import SwiftUI

struct AccountIdentitySection: View {
    let account: AccountIdentity?

    var body: some View {
        Section("Account") {
            if let account, !account.isEmpty {
                if let email = account.email {
                    AccountField(title: "Email", value: email)
                }
                if let name = account.name {
                    AccountField(title: "Name", value: name)
                }
                if let plan = account.plan {
                    AccountField(title: "Plan", value: plan)
                }
                if let organization = account.organization {
                    AccountField(title: "Organization", value: organization)
                }
            } else {
                AccountField(title: "Account details", value: "Not available")
            }
        }
    }
}
