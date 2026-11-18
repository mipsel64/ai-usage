import Foundation
import Testing
@testable import QuotaCore

@Suite final class ClaudeUsageTests: Sendable {
    private let directory: URL
    private let snapshotURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        snapshotURL = directory.appendingPathComponent("claude.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func desktopReadingPreservesObservationAndResetDeadline() throws {
        let now = Date(timeIntervalSince1970: 1_738_000_000)
        try Data("""
        {"observedAt":1737999970,"rateLimits":[
          {"kind":"five_hour","percentUsed":12.5,"resetsAt":1738000120},
          {"kind":"seven_day","percentUsed":0}]}
        """.utf8).write(to: snapshotURL)
        let result = try ClaudeUsage.readDesktop(from: snapshotURL, now: now)
        #expect(result.observedAt == now.addingTimeInterval(-30))
        #expect(result.windows == [
            .init(id: "five_hour", title: "5-hour limit", remainingPercent: 87.5, resetAt: now.addingTimeInterval(120)),
            .init(id: "seven_day", title: "7-day limit", remainingPercent: 100, resetAt: nil)
        ])
        #expect(throws: QuotaError.unavailable) {
            try ClaudeUsage.readDesktop(from: snapshotURL, now: now.addingTimeInterval(300))
        }
    }

    @Test func incompleteDesktopWriteIsNotAnObservation() throws {
        try Data(#"{"rateLimits":[{"kind":"five_hour","percentUsed":"#.utf8).write(to: snapshotURL)
        #expect(throws: QuotaError.invalidResponse) { try ClaudeUsage.readDesktop(from: snapshotURL, now: .now) }
    }

    @Test func desktopFeedDoesNotFollowASymbolicLink() throws {
        let target = directory.appendingPathComponent("another-file")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: target)
        #expect(throws: QuotaError.unavailable) { try ClaudeUsage.readDesktop(from: snapshotURL, now: .now) }
    }

    @Test func captureNormalizesOnlyQuotaFields() throws {
        let observedAt = Date(timeIntervalSince1970: 1_738_000_000)
        let fiveHourReset = Date(timeIntervalSince1970: 1_738_001_000)
        let sevenDayReset = Date(timeIntervalSince1970: 1_738_100_000)
        let input = Data("""
        {
          "session_id": "private-session",
          "transcript_path": "/private/transcript.jsonl",
          "model": { "display_name": "Opus" },
          "rate_limits": {
            "five_hour": { "used_percentage": 23.5, "resets_at": 1738001000 },
            "seven_day": { "used_percentage": 41.2, "resets_at": 1738100000 }
          }
        }
        """.utf8)

        let status = try ClaudeUsage.captureStatusLine(
            input: input,
            snapshotURL: snapshotURL,
            observedAt: observedAt
        )

        #expect(status == "Claude 5h 76% left · 7d 59% left")
        let snapshot = try ClaudeUsage.read(from: snapshotURL, now: observedAt)
        #expect(snapshot.observedAt == observedAt)
        #expect(snapshot.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(abs(snapshot.windows[0].remainingPercent - 76.5) < 0.0001)
        #expect(abs(snapshot.windows[1].remainingPercent - 58.8) < 0.0001)
        #expect(snapshot.windows[0].resetAt == fiveHourReset)
        #expect(snapshot.windows[1].resetAt == sevenDayReset)

        let stored = try Data(contentsOf: snapshotURL)
        let object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(Set(object.keys) == ["windows", "observedAt"])
        let text = String(decoding: stored, as: UTF8.self)
        #expect(!text.contains("private-session"))
        #expect(!text.contains("transcript"))
        #expect(!text.contains("Opus"))
    }

    @Test func testMissingRateLimitsDoesNotReplaceLastSnapshot() throws {
        let observedAt = Date(timeIntervalSince1970: 1_738_000_000)
        try captureFiveHour(used: 20, observedAt: observedAt)

        let status = try ClaudeUsage.captureStatusLine(
            input: Data("{}".utf8),
            snapshotURL: snapshotURL,
            observedAt: observedAt.addingTimeInterval(10)
        )

        #expect(status == "Claude quota not reported yet")
        let snapshot = try ClaudeUsage.read(
            from: snapshotURL,
            now: observedAt.addingTimeInterval(10)
        )
        #expect(snapshot.observedAt == observedAt)
        #expect(snapshot.windows.first?.remainingPercent == 80)
    }

    @Test func testCaptureRejectsInvalidSubscriptionPercentagesWithoutWriting() {
        for used in [-1, 100.1] {
            let input = Data("""
            {"rate_limits":{"five_hour":{"used_percentage":\(used),"resets_at":1738001000}}}
            """.utf8)
            #expect(throws: QuotaError.invalidResponse) {
                _ = try ClaudeUsage.captureStatusLine(
                    input: input,
                    snapshotURL: snapshotURL,
                    observedAt: Date(timeIntervalSince1970: 1_738_000_000)
                )
            }
        }
        #expect(!FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    @Test func testSpendLimitOverDocumentedMaximumClampsRemainingToZero() throws {
        let observedAt = Date(timeIntervalSince1970: 1_738_000_000)
        let input = Data("""
        {"rate_limits":{"spend_limit":{"used_percentage":105,"resets_at":1738001000}}}
        """.utf8)

        let status = try ClaudeUsage.captureStatusLine(
            input: input,
            snapshotURL: snapshotURL,
            observedAt: observedAt
        )

        #expect(status == "Claude spend 0% left")
        let snapshot = try ClaudeUsage.read(from: snapshotURL, now: observedAt)
        #expect(snapshot.windows.first?.remainingPercent == 0)
    }

    @Test func testUnreportedResetRemainsNil() throws {
        let observedAt = Date(timeIntervalSince1970: 1_738_000_000)
        let input = Data("""
        {"rate_limits":{"seven_day":{"used_percentage":40}}}
        """.utf8)
        _ = try ClaudeUsage.captureStatusLine(
            input: input,
            snapshotURL: snapshotURL,
            observedAt: observedAt
        )

        let snapshot = try ClaudeUsage.read(from: snapshotURL, now: observedAt)
        #expect(snapshot.windows.first?.resetAt == nil)
    }

    @Test func testReadRejectsStaleSnapshot() throws {
        let observedAt = Date(timeIntervalSince1970: 1_738_000_000)
        try captureFiveHour(used: 20, observedAt: observedAt)

        #expect(throws: QuotaError.unavailable) {
            _ = try ClaudeUsage.read(
                from: snapshotURL,
                now: observedAt.addingTimeInterval(ClaudeUsage.maximumSnapshotAge + 1)
            )
        }
    }

    @Test func testReadRejectsSnapshotFromTooFarInFuture() throws {
        let observedAt = Date(timeIntervalSince1970: 1_738_000_000)
        try captureFiveHour(used: 20, observedAt: observedAt)

        #expect(throws: QuotaError.unavailable) {
            _ = try ClaudeUsage.read(
                from: snapshotURL,
                now: observedAt.addingTimeInterval(-61)
            )
        }
    }

    @Test func testReadPreservesExpiredDeadlineUntilNextCapture() throws {
        let observedAt = Date(timeIntervalSince1970: 1_738_000_000)
        let input = Data("""
        {"rate_limits":{
          "five_hour":{"used_percentage":20,"resets_at":1737999000},
          "seven_day":{"used_percentage":40,"resets_at":1738001000}
        }}
        """.utf8)
        _ = try ClaudeUsage.captureStatusLine(
            input: input,
            snapshotURL: snapshotURL,
            observedAt: observedAt
        )

        let snapshot = try ClaudeUsage.read(from: snapshotURL, now: observedAt)
        #expect(snapshot.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(snapshot.windows.first?.resetAt == Date(timeIntervalSince1970: 1_737_999_000))
    }

    @Test func testReadRejectsSnapshotWhoseWindowsAllExpired() throws {
        let observedAt = Date(timeIntervalSince1970: 1_738_000_000)
        try captureFiveHour(used: 20, observedAt: observedAt)

        #expect(throws: QuotaError.unavailable) {
            _ = try ClaudeUsage.read(
                from: snapshotURL,
                now: observedAt.addingTimeInterval(120)
            )
        }
    }

    @Test func testReadMissingFileReportsNotConfigured() {
        #expect(throws: QuotaError.notConfigured) {
            _ = try ClaudeUsage.read(from: snapshotURL, now: Date())
        }
    }

    @Test func testReadRejectsCorruptSnapshot() throws {
        try Data("not json".utf8).write(to: snapshotURL)

        #expect(throws: QuotaError.invalidResponse) {
            _ = try ClaudeUsage.read(from: snapshotURL, now: Date())
        }
    }

    @Test func testReadRejectsOversizedSnapshot() throws {
        let data = Data(repeating: 0x20, count: ClaudeUsage.maximumSnapshotBytes + 1)
        try data.write(to: snapshotURL)

        #expect(throws: QuotaError.invalidResponse) {
            _ = try ClaudeUsage.read(from: snapshotURL, now: Date())
        }
    }

    @Test func testValidationRejectsNonFiniteAndOutOfRangeRemainingValues() {
        let now = Date(timeIntervalSince1970: 1_738_000_000)
        for remaining in [Double.nan, .infinity, -.infinity, -0.1, 100.1] {
            let snapshot = QuotaSnapshot(
                windows: [QuotaWindow(
                    id: "five_hour",
                    title: "5-hour limit",
                    remainingPercent: remaining,
                    resetAt: now.addingTimeInterval(1000)
                )],
                observedAt: now
            )
            #expect(throws: QuotaError.invalidResponse) {
                _ = try ClaudeUsage.validatedSnapshot(snapshot, now: now)
            }
        }
    }

    @Test func testReadRejectsDuplicateWindowIdentifiers() throws {
        let now = Date(timeIntervalSince1970: 1_738_000_000)
        let window = QuotaWindow(
            id: "five_hour",
            title: "5-hour limit",
            remainingPercent: 80,
            resetAt: now.addingTimeInterval(1000)
        )
        try writeSnapshot(QuotaSnapshot(windows: [window, window], observedAt: now))

        #expect(throws: QuotaError.invalidResponse) {
            _ = try ClaudeUsage.read(from: snapshotURL, now: now)
        }
    }

    @Test func testCaptureRejectsMalformedStatusLineJSON() {
        #expect(throws: QuotaError.invalidResponse) {
            _ = try ClaudeUsage.captureStatusLine(
                input: Data("{".utf8),
                snapshotURL: snapshotURL,
                observedAt: Date()
            )
        }
    }

    private func captureFiveHour(used: Double, observedAt: Date) throws {
        let reset = Int(observedAt.addingTimeInterval(60).timeIntervalSince1970)
        let input = Data("""
        {"rate_limits":{"five_hour":{"used_percentage":\(used),"resets_at":\(reset)}}}
        """.utf8)
        _ = try ClaudeUsage.captureStatusLine(
            input: input,
            snapshotURL: snapshotURL,
            observedAt: observedAt
        )
    }

    private func writeSnapshot(_ snapshot: QuotaSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotURL)
    }
}
