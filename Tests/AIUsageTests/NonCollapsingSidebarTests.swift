import Foundation
import Testing
@testable import AIUsage

@MainActor
struct NonCollapsingSidebarTests {
    @Test func forgetSavedLayoutRemovesOnlyTheSidebarFrames() throws {
        let suite = "AIUsage.Tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "NSSplitView Subview Frames com_apple_SwiftUI_Settings_window, SidebarNavigationSplitView"
        defaults.set(["0.000000, 0.000000, 220.000000, 492.000000, YES, NO"], forKey: key)
        defaults.set(true, forKey: "notify")

        NonCollapsingSidebar.forgetSavedLayout(in: defaults)

        #expect(defaults.object(forKey: key) == nil)
        #expect(defaults.bool(forKey: "notify"))
    }
}
