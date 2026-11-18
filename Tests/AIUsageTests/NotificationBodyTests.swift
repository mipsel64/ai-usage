import Testing
import QuotaCore
@testable import AIUsage

@MainActor
struct NotificationBodyTests {
    private let fiveHour = QuotaWindow(id: "5h", title: "5-hour limit", remainingPercent: 15, resetAt: nil)
    private let weekly = QuotaWindow(id: "7d", title: "7-day limit", remainingPercent: 5, resetAt: nil)

    @Test func resetThenLowWindow() {
        #expect(UsageStore.notificationBody(reset: true, credit: false, low: [(fiveHour, 20)])
            == "Quota refreshed.\n5-hour limit is below 20%.")
    }

    @Test func twoLowWindows() {
        #expect(UsageStore.notificationBody(reset: false, credit: false, low: [(fiveHour, 20), (weekly, 10)])
            == "5-hour limit is below 20%.\n7-day limit is below 10%.")
    }

    @Test func lowOnly() {
        #expect(UsageStore.notificationBody(reset: false, credit: false, low: [(weekly, 20)]) == "7-day limit is below 20%.")
    }
}
