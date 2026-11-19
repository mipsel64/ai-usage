import QuotaCore
import SwiftUI

struct AccountIdentitySection: View {
    let account: AccountIdentity?

    var body: some View {
        let shown = account.map { Self.current($0, at: .now) }
        Section("Account") {
            if let account = shown, !account.isEmpty {
                if let email = account.email {
                    AccountField(title: "Email", value: email)
                }
                if let name = account.name {
                    AccountField(title: "Name", value: name)
                }
                if let plan = account.plan {
                    AccountField(title: "Plan", value: plan)
                }
                if let periodEnd = account.periodEnd {
                    AccountField(
                        title: Self.periodTitle(renews: account.renews),
                        value: periodEnd.formatted(date: .abbreviated, time: .omitted)
                    )
                }
                if let organization = account.organization {
                    AccountField(title: "Organization", value: organization)
                }
            } else {
                AccountField(title: "Account details", value: "Not available")
            }
        }
    }

    static func periodTitle(renews: Bool?) -> String {
        switch renews {
        case true?: "Renews"
        case false?: "Ends"
        case nil: "Current period ends"
        }
    }

    /// A period that has ended is not shown.
    private static func current(_ account: AccountIdentity, at now: Date) -> AccountIdentity {
        guard let periodEnd = account.periodEnd, periodEnd <= now else { return account }
        return AccountIdentity(
            email: account.email, name: account.name, plan: account.plan, organization: account.organization
        )
    }
}
