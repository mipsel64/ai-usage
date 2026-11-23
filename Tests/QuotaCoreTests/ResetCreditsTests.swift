import Foundation
import Testing
@testable import QuotaCore

struct ResetCreditsTests {
    @Test func groupUsesEarliestExpiryAndSkipsZeroCounts() {
        let later = Date(timeIntervalSince1970: 2_000)
        let earlier = Date(timeIntervalSince1970: 1_000)

        let option = ResetOption.group([
            (id: "later", count: 2, expiry: later),
            (id: "zero", count: 0, expiry: earlier),
            (id: "earlier", count: 1, expiry: earlier),
            (id: "negative", count: -1, expiry: nil),
        ], title: "Full reset", detail: nil)

        #expect(option == ResetOption(id: "earlier", title: "Full reset", detail: nil, count: 3, expiry: earlier))
    }

    @Test func groupSortsMissingExpiryLast() {
        let expiry = Date(timeIntervalSince1970: 1_000)

        let option = ResetOption.group([
            (id: "permanent", count: 1, expiry: nil),
            (id: "dated", count: 1, expiry: expiry),
        ], title: "Full reset", detail: nil)

        #expect(option?.id == "dated")
        #expect(option?.expiry == expiry)
    }

    @Test func groupReturnsNilWithoutPositiveCount() {
        #expect(ResetOption.group([], title: "Full reset", detail: nil) == nil)
        #expect(ResetOption.group([(id: "zero", count: 0, expiry: nil)], title: "Full reset", detail: nil) == nil)
    }

    @Test func decodesStoredCreditsWithoutOptions() throws {
        let body = Data(#"{"availableCount":1,"nextID":"x","nextTitle":null,"nextExpiry":null}"#.utf8)

        let credits = try JSONDecoder().decode(ResetCredits.self, from: body)

        #expect(credits == ResetCredits(availableCount: 1))
    }

    @Test func rejectsStoredCreditsWithoutAvailableCount() {
        let body = Data(#"{"options":[]}"#.utf8)

        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(ResetCredits.self, from: body)
        }
    }
}
