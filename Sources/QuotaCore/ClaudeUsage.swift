import Darwin
import Foundation

/// Reads local quota observations from Claude Code's status line or Desktop plugin.
public enum ClaudeUsage {
    static let maximumSnapshotAge: TimeInterval = 5 * 60
    static let maximumSnapshotBytes = 64 * 1024
    private static let allowedFutureSkew: TimeInterval = 60

    static func read(_ access: ProviderAccess) throws -> QuotaSnapshot {
        switch access {
        case .local: try read(from: defaultSnapshotURL(), now: Date())
        case .desktopFeed: try readDesktop(from: defaultSnapshotURL("claude-desktop.json"), now: Date())
        default: throw QuotaError.notConfigured
        }
    }

    /// Consumes one status-line payload, persists only its quota data, and returns a standalone status line.
    public static func captureStatusLine(input: Data) throws -> String {
        try captureStatusLine(input: input, snapshotURL: defaultSnapshotURL(), observedAt: Date())
    }

    static func captureStatusLine(
        input: Data,
        snapshotURL: URL,
        observedAt: Date
    ) throws -> String {
        let snapshot = try snapshot(from: input, observedAt: observedAt)
        if !snapshot.windows.isEmpty {
            try write(snapshot, to: snapshotURL)
        }
        return statusLine(for: snapshot, now: observedAt)
    }

    static func snapshot(from input: Data, observedAt: Date) throws -> QuotaSnapshot {
        guard observedAt.timeIntervalSince1970.isFinite else { throw QuotaError.invalidResponse }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let status: StatusLinePayload
        do {
            status = try decoder.decode(StatusLinePayload.self, from: input)
        } catch {
            throw QuotaError.invalidResponse
        }

        let windows = [
            try window(id: "five_hour", title: "5-hour limit", value: status.rateLimits?.fiveHour),
            try window(id: "seven_day", title: "7-day limit", value: status.rateLimits?.sevenDay),
            try window(id: "spend_limit", title: "Spend limit", value: status.rateLimits?.spendLimit)
        ].compactMap { $0 }
        return QuotaSnapshot(windows: windows, observedAt: observedAt)
    }

    static func read(from url: URL, now: Date) throws -> QuotaSnapshot {
        let data = try readBounded(from: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: QuotaSnapshot
        do {
            snapshot = try decoder.decode(QuotaSnapshot.self, from: data)
        } catch {
            throw QuotaError.invalidResponse
        }
        return try validatedSnapshot(snapshot, now: now)
    }

    static func readDesktop(from url: URL, now: Date) throws -> QuotaSnapshot {
        let data = try readBounded(from: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let feed = try? decoder.decode(DesktopFeed.self, from: data),
              (1...2).contains(feed.rateLimits.count) else { throw QuotaError.invalidResponse }
        let windows = try feed.rateLimits.map { limit in
            let title: String
            switch limit.kind {
            case "five_hour": title = "5-hour limit"
            case "seven_day": title = "7-day limit"
            default: throw QuotaError.invalidResponse
            }
            guard (0...100).contains(limit.percentUsed) else { throw QuotaError.invalidResponse }
            return QuotaWindow(id: limit.kind, title: title, remainingPercent: 100 - limit.percentUsed, resetAt: limit.resetsAt)
        }
        return try validatedSnapshot(QuotaSnapshot(windows: windows, observedAt: feed.observedAt), now: now)
    }

    static func validatedSnapshot(_ snapshot: QuotaSnapshot, now: Date) throws -> QuotaSnapshot {
        guard snapshot.observedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite else {
            throw QuotaError.invalidResponse
        }

        let age = now.timeIntervalSince(snapshot.observedAt)
        guard age >= -allowedFutureSkew, age <= maximumSnapshotAge else {
            throw QuotaError.unavailable
        }
        guard !snapshot.windows.isEmpty, snapshot.windows.count <= 3 else {
            throw QuotaError.invalidResponse
        }

        let knownIDs = Set(["five_hour", "seven_day", "spend_limit"])
        var seenIDs = Set<String>()
        for window in snapshot.windows {
            guard knownIDs.contains(window.id), seenIDs.insert(window.id).inserted,
                  window.remainingPercent.isFinite,
                  (0...100).contains(window.remainingPercent) else {
                throw QuotaError.invalidResponse
            }
            if let resetAt = window.resetAt, !resetAt.timeIntervalSince1970.isFinite {
                throw QuotaError.invalidResponse
            }
        }

        guard snapshot.windows.contains(where: { $0.resetAt.map { $0 > now } ?? true }) else {
            throw QuotaError.unavailable
        }
        // Keep the expired deadline so the next capture can identify the renewed window.
        return snapshot
    }

    static func write(_ snapshot: QuotaSnapshot, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw QuotaError.unavailable
        }
    }

    private static func window(
        id: String,
        title: String,
        value: RateLimitWindow?
    ) throws -> QuotaWindow? {
        guard let used = value?.usedPercentage else { return nil }
        guard used.isFinite, used >= 0 else { throw QuotaError.invalidResponse }
        // Anthropic documents that a gateway spend limit alone may exceed 100%.
        guard used <= 100 || id == "spend_limit" else { throw QuotaError.invalidResponse }
        if let resetAt = value?.resetAt, !resetAt.timeIntervalSince1970.isFinite {
            throw QuotaError.invalidResponse
        }
        return QuotaWindow(
            id: id,
            title: title,
            remainingPercent: min(100, max(0, 100 - used)),
            resetAt: value?.resetAt
        )
    }

    private static func statusLine(for snapshot: QuotaSnapshot, now: Date) -> String {
        let activeWindows = snapshot.windows.filter { window in
            guard let resetAt = window.resetAt else { return true }
            return resetAt > now
        }
        guard !activeWindows.isEmpty else { return "Claude quota not reported yet" }
        let parts = activeWindows.map { window -> String in
            let label = switch window.id {
            case "five_hour": "5h"
            case "seven_day": "7d"
            default: "spend"
            }
            // Match the official examples' printf("%.0f") rounding, including halfway values.
            let remaining = String(format: "%.0f", locale: nil, window.remainingPercent)
            return "\(label) \(remaining)% left"
        }
        return "Claude " + parts.joined(separator: " · ")
    }

    private static func defaultSnapshotURL(_ filename: String = "claude.json") throws -> URL {
        do {
            return try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("ai-usage", isDirectory: true)
            .appendingPathComponent(filename)
        } catch {
            throw QuotaError.unavailable
        }
    }

    private static func readBounded(from url: URL) throws -> Data {
        let fd = try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw QuotaError.unavailable }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw errno == ENOENT ? QuotaError.notConfigured : QuotaError.unavailable }
            return fd
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
            throw QuotaError.unavailable
        }

        do {
            let data = try handle.read(upToCount: maximumSnapshotBytes + 1) ?? Data()
            guard data.count <= maximumSnapshotBytes else { throw QuotaError.invalidResponse }
            return data
        } catch let error as QuotaError {
            throw error
        } catch {
            throw QuotaError.unavailable
        }
    }
}

private struct DesktopFeed: Decodable {
    struct Limit: Decodable {
        let kind: String
        let percentUsed: Double
        let resetsAt: Date?
    }
    let rateLimits: [Limit]
    let observedAt: Date
}

private struct StatusLinePayload: Decodable {
    let rateLimits: RateLimits?

    enum CodingKeys: String, CodingKey {
        case rateLimits = "rate_limits"
    }
}

private struct RateLimits: Decodable {
    let fiveHour: RateLimitWindow?
    let sevenDay: RateLimitWindow?
    let spendLimit: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case spendLimit = "spend_limit"
    }
}

private struct RateLimitWindow: Decodable {
    let usedPercentage: Double?
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetAt = "resets_at"
    }
}
