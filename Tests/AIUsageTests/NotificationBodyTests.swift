import Testing
import QuotaCore
@testable import AIUsage

@MainActor
struct NotificationBodyTests {
    private let fiveHour = QuotaWindow(id: "5h", title: "5-hour", remainingPercent: 15, resetAt: nil)
    private let weekly = QuotaWindow(id: "7d", title: "Weekly", remainingPercent: 5, resetAt: nil)

    @Test func refreshedThenLowWindow() {
        #expect(UsageStore.notificationBody(refreshed: [weekly], credit: false, low: [(fiveHour, 20)])
            == "Weekly limit refreshed.\n5-hour limit is below 20%.")
    }

    @Test func twoRefreshedWindowsAndCredit() {
        #expect(UsageStore.notificationBody(refreshed: [fiveHour, weekly], credit: true, low: [])
            == "5-hour limit refreshed.\nWeekly limit refreshed.\nA new reset credit is available.")
    }

    @Test func twoLowWindows() {
        #expect(UsageStore.notificationBody(refreshed: [], credit: false, low: [(fiveHour, 20), (weekly, 10)])
            == "5-hour limit is below 20%.\nWeekly limit is below 10%.")
    }

    @Test func lowOnly() {
        #expect(UsageStore.notificationBody(refreshed: [], credit: false, low: [(weekly, 20)]) == "Weekly limit is below 20%.")
    }
}
