import ServiceManagement
import Testing
@testable import AIUsage

struct LoginItemTests {
    @Test func loginItemStatusSetsToggleAndApprovalHint() {
        #expect(GeneralPanel.loginItem(for: .enabled) == (isOn: true, needsApproval: false))
        #expect(GeneralPanel.loginItem(for: .requiresApproval) == (isOn: true, needsApproval: true))
        #expect(GeneralPanel.loginItem(for: .notRegistered) == (isOn: false, needsApproval: false))
        #expect(GeneralPanel.loginItem(for: .notFound) == (isOn: false, needsApproval: false))
    }
}
