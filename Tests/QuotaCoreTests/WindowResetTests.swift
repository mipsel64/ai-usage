import Foundation
import Testing
@testable import QuotaCore

struct WindowResetTests {
    func sample(_ time: Double, _ percent: Double, _ deadline: Double?, id: String = "weekly") -> QuotaSnapshot {
        QuotaSnapshot(windows: [.init(id: id, title: "Window", remainingPercent: percent,
                                     resetAt: deadline.map { Date(timeIntervalSince1970: $0) })],
                      observedAt: Date(timeIntervalSince1970: time))
    }

    @Test func detectsNewPeriodEvenAfterSomeQuotaIsAlreadySpent() {
        let first = sample(10, 30, 50)
        let next = sample(55, 20, 100)
        #expect(next.refreshedWindows(since: first) == next.windows)
        #expect(next.refreshedWindows(since: next).isEmpty)
    }

    @Test func detectsRestorationBeforeDeadline() {
        let old = sample(10, 25, 50)
        let full = sample(20, 100, 50)
        #expect(full.refreshedWindows(since: old) == full.windows)
    }

    @Test func rejectsDeadlineDriftUnrelatedWindowsAndOldReadings() {
        let old = sample(10, 25, 50)
        #expect(sample(20, 24, 65).refreshedWindows(since: old).isEmpty)
        #expect(sample(9, 100, 65).refreshedWindows(since: old).isEmpty)
        #expect(sample(60, 100, 80, id: "daily").refreshedWindows(since: old).isEmpty)
        #expect(sample(60, 25, 50).refreshedWindows(since: old).isEmpty)
    }

    @Test func skipsWindowsThatHadMoreThan80PercentLeftBeforeTheRefresh() {
        let newPeriod = sample(55, 100, 100)
        #expect(newPeriod.refreshedWindows(since: sample(10, 99, 50)).isEmpty)
        #expect(sample(20, 100, 50).refreshedWindows(since: sample(10, 99, 50)).isEmpty)
        #expect(newPeriod.refreshedWindows(since: sample(10, 80.5, 50)).isEmpty)
        #expect(newPeriod.refreshedWindows(since: sample(10, 80, 50)) == newPeriod.windows)
    }

    @Test func appliesThe80PercentRuleToEachWindowOnItsOwn() {
        func window(_ id: String, _ percent: Double, _ deadline: Double) -> QuotaWindow {
            .init(id: id, title: id, remainingPercent: percent, resetAt: Date(timeIntervalSince1970: deadline))
        }
        let old = QuotaSnapshot(windows: [window("5h", 99, 50), window("weekly", 30, 50)], observedAt: Date(timeIntervalSince1970: 10))
        let next = QuotaSnapshot(windows: [window("5h", 95, 100), window("weekly", 95, 100)], observedAt: Date(timeIntervalSince1970: 55))
        #expect(next.refreshedWindows(since: old).map(\.id) == ["weekly"])
    }
}
