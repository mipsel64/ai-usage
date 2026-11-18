import Foundation
import Testing
@testable import QuotaCore

struct LowQuotaTests {
    func sample(_ time: Double, _ percents: [String: Double]) -> QuotaSnapshot {
        QuotaSnapshot(windows: percents.keys.sorted().map { .init(id: $0, title: $0, remainingPercent: percents[$0]!, resetAt: nil) },
                      observedAt: Date(timeIntervalSince1970: time))
    }

    func crossings(_ before: Double, _ after: Double) -> [Int] {
        sample(20, ["weekly": after]).lowWindows(since: sample(10, ["weekly": before])).map(\.threshold)
    }

    @Test func reportsLowestCrossedThreshold() {
        #expect(crossings(25, 19) == [20])
        #expect(crossings(25, 8) == [10])
        #expect(crossings(19, 18).isEmpty)
        #expect(crossings(19, 9) == [10])
        #expect(crossings(20, 19.9) == [20])
        #expect(crossings(9, 100).isEmpty)
    }

    @Test func ignoresOldReadingsAndNewWindows() {
        let old = sample(10, ["weekly": 25])
        #expect(sample(10, ["weekly": 5]).lowWindows(since: old).isEmpty)
        #expect(sample(9, ["weekly": 5]).lowWindows(since: old).isEmpty)
        #expect(sample(20, ["daily": 5]).lowWindows(since: old).isEmpty)
    }

    @Test func reportsEveryWindowThatCrosses() {
        let old = sample(10, ["daily": 50, "weekly": 15])
        let low = sample(20, ["daily": 12, "weekly": 3]).lowWindows(since: old)
        #expect(low.map(\.window.id) == ["daily", "weekly"])
        #expect(low.map(\.threshold) == [20, 10])
    }
}
