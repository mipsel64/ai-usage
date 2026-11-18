import Darwin
import Foundation

public enum CodexUsage {
    static let signatureRequirement = SignedExecutable(team: "2DC432GLL2", identifier: "codex")

    private static let requestTimeout: TimeInterval = 20
    private static let redemptionTimeout: TimeInterval = 30

    /// Reads usage through Codex's own app-server, which owns the existing sign-in.
    /// Protocol: https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt
    public static func fetch(executable: URL) async throws -> QuotaSnapshot {
        try validateExecutable(executable)
        return try await fetch(
            executable: executable,
            session: CodexProcessSession(),
            timeout: requestTimeout,
            observedAt: nil
        )
    }

    /// Consumes one earned reset. There are no retries, purchases, or fallback endpoints.
    /// Protocol: https://learn.chatgpt.com/docs/app-server#8-earned-rate-limit-resets-chatgpt
    public static func redeem(
        executable: URL,
        creditID: String,
        idempotencyKey: String
    ) async throws -> Redemption {
        try validateExecutable(executable)
        return try await redeem(
            executable: executable,
            creditID: creditID,
            idempotencyKey: idempotencyKey,
            session: CodexProcessSession(),
            timeout: redemptionTimeout,
            observedAt: nil
        )
    }

    static func fetch(
        executable: URL,
        session: any CodexUsageSession,
        timeout: TimeInterval,
        observedAt: Date?
    ) async throws -> QuotaSnapshot {
        try await run(session: session, timeout: timeout) { send in
            try session.start(executable: executable)
            try initialize(session: session, send: send)
            let result = try request(
                session: session,
                send: send,
                id: 2,
                method: "account/rateLimits/read"
            )
            return try decodeSnapshot(result: result, observedAt: observedAt)
        }
    }

    static func redeem(
        executable: URL,
        creditID: String,
        idempotencyKey: String,
        session: any CodexUsageSession,
        timeout: TimeInterval,
        observedAt: Date?
    ) async throws -> Redemption {
        guard !idempotencyKey.isEmpty, !creditID.isEmpty else { throw QuotaError.notConfigured }

        return try await run(session: session, timeout: timeout) { send in
            try session.start(executable: executable)
            try initialize(session: session, send: send)

            // A fresh preflight prevents redeeming a spent, expired, or different exact credit.
            let current = try request(
                session: session,
                send: send,
                id: 2,
                method: "account/rateLimits/read"
            )
            let response = try decode(CodexRateLimitsResponse.self, from: current)
            let credits = try response.resetCredits(observedAt: observedAt ?? Date())
            guard credits.availableCount > 0 else { return .noCredit }
            guard credits.eligibleCreditIDs.contains(creditID) else { return .noCredit }

            let params: [String: Any] = [
                "idempotencyKey": idempotencyKey,
                "creditId": creditID,
            ]
            let result = try request(
                session: session,
                send: send,
                id: 3,
                method: "account/rateLimitResetCredit/consume",
                params: params
            )
            let redemption = try decode(CodexRedemptionResponse.self, from: result)
            switch redemption.outcome {
            case "reset": return .reset
            case "alreadyRedeemed": return .alreadyRedeemed
            case "nothingToReset": return .nothingToReset
            case "noCredit": return .noCredit
            default: throw QuotaError.invalidResponse
            }
        }
    }

    static func validateExecutable(_ executable: URL) throws {
        guard executable.isFileURL, executable.path.hasPrefix("/") else {
            throw QuotaError.notConfigured
        }
        let resolved = executable.standardizedFileURL.resolvingSymlinksInPath()
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            FileManager.default.isExecutableFile(atPath: resolved.path)
        else {
            throw QuotaError.notConfigured
        }
    }

    private static func initialize(
        session: any CodexUsageSession,
        send: CodexSend
    ) throws {
        _ = try request(
            session: session,
            send: send,
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "ai_usage",
                    "title": "AI Usage",
                    "version": "1.0.0",
                ]
            ]
        )
        try send(["method": "initialized", "params": [:]])
    }

    private static func request(
        session: any CodexUsageSession,
        send: CodexSend,
        id: Int,
        method: String,
        params: [String: Any]? = nil
    ) throws -> [String: Any] {
        var message: [String: Any] = ["method": method, "id": id]
        if let params { message["params"] = params }
        try send(message)

        while true {
            let incoming = try session.readMessage()
            guard (incoming["id"] as? Int) == id else { continue }
            if let error = incoming["error"] as? [String: Any] {
                throw quotaError(forRPCError: error)
            }
            guard let result = incoming["result"] as? [String: Any] else {
                throw QuotaError.invalidResponse
            }
            return result
        }
    }

    private static func quotaError(forRPCError error: [String: Any]) -> QuotaError {
        switch error["code"] as? Int {
        case 401, 403:
            .unauthorized
        case 429, -32001:
            .rateLimited
        default:
            .invalidResponse
        }
    }

    private static func decodeSnapshot(
        result: [String: Any],
        observedAt: Date?
    ) throws -> QuotaSnapshot {
        let receivedAt = observedAt ?? Date()
        let response = try decode(CodexRateLimitsResponse.self, from: result)
        let windows = try response.quotaWindows()
        guard !windows.isEmpty else { throw QuotaError.invalidResponse }
        return try QuotaSnapshot(
            windows: windows,
            observedAt: receivedAt,
            resetCredits: response.resetCredits(observedAt: receivedAt).summary
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw QuotaError.invalidResponse
        }
    }

    private static func run<Value: Sendable>(
        session: any CodexUsageSession,
        timeout: TimeInterval,
        operation: @escaping (CodexSend) throws -> Value
    ) async throws -> Value {
        let operation = CodexSessionOperation(session: session, body: operation)
        let resumer = CodexResumeOnce<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resumer.install(continuation)
                guard !resumer.isClaimed else { return }

                DispatchQueue.global(qos: .userInitiated).async {
                    let result: Result<Value, Error>
                    do {
                        let send: CodexSend = { message in
                            try resumer.performUnclaimed {
                                try operation.session.send(message)
                            }
                        }
                        result = .success(try operation.run(send: send))
                    } catch let error as QuotaError {
                        result = .failure(error)
                    } catch {
                        result = .failure(QuotaError.unavailable)
                    }
                    // Claim first so timeout cannot interrupt a completed operation during cleanup.
                    guard resumer.claim(result) else { return }
                    operation.session.close()
                    resumer.finishClaimed()
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    guard resumer.claim(.failure(QuotaError.unavailable)) else { return }
                    operation.session.interrupt()
                    resumer.finishClaimed()
                }
            }
        } onCancel: {
            guard resumer.claim(.failure(CancellationError())) else { return }
            operation.session.interrupt()
            resumer.finishClaimed()
        }
    }
}

private typealias CodexSend = (_ message: [String: Any]) throws -> Void

protocol CodexUsageSession: AnyObject {
    func start(executable: URL) throws
    func send(_ message: [String: Any]) throws
    func readMessage() throws -> [String: Any]
    func close()
    func interrupt()
}

private struct CodexSessionOperation<Value: Sendable>: @unchecked Sendable {
    let session: any CodexUsageSession
    let body: (CodexSend) throws -> Value

    func run(send: CodexSend) throws -> Value { try body(send) }
}

private final class CodexResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var claimedResult: Result<Value, Error>?
    private var isDelivered = false

    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimedResult != nil
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let claimedResult, !isDelivered {
            isDelivered = true
            lock.unlock()
            continuation.resume(with: claimedResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// Holds the same lock as `claim`, so a timeout either precedes the write or follows it.
    func performUnclaimed(_ body: () throws -> Void) throws {
        lock.lock()
        guard claimedResult == nil else {
            lock.unlock()
            throw QuotaError.unavailable
        }
        do {
            try body()
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    func claim(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard claimedResult == nil else { return false }
        claimedResult = result
        return true
    }

    func finishClaimed() {
        lock.lock()
        guard let claimedResult, let continuation, !isDelivered else {
            lock.unlock()
            return
        }
        isDelivered = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: claimedResult)
    }
}

private struct CodexRateLimitsResponse: Decodable {
    let rateLimits: CodexRateLimitSnapshot
    let rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?
    let rateLimitResetCredits: CodexResetCreditsSummary?

    func quotaWindows() throws -> [QuotaWindow] {
        let buckets: [(String, CodexRateLimitSnapshot)]
        if let rateLimitsByLimitId, !rateLimitsByLimitId.isEmpty {
            buckets = rateLimitsByLimitId.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else {
            buckets = [(rateLimits.limitId ?? "codex", rateLimits)]
        }

        var windows: [QuotaWindow] = []
        for (key, bucket) in buckets {
            let bucketID = bucket.limitId ?? key
            let bucketTitle = bucket.limitName ?? (bucketID == "codex" ? "Codex" : bucketID)
            if let primary = bucket.primary {
                windows.append(try primary.quotaWindow(
                    id: "\(key).primary",
                    title: "\(bucketTitle) Primary"
                ))
            }
            if let secondary = bucket.secondary {
                windows.append(try secondary.quotaWindow(
                    id: "\(key).secondary",
                    title: "\(bucketTitle) Secondary"
                ))
            }
        }
        return windows
    }

    func resetCredits(observedAt: Date) throws -> CodexEligibleCredits {
        guard let rateLimitResetCredits else {
            return CodexEligibleCredits(summary: nil, eligibleCreditIDs: [])
        }
        guard rateLimitResetCredits.availableCount >= 0 else {
            throw QuotaError.invalidResponse
        }

        let now = observedAt.timeIntervalSince1970
        // Official RateLimitResetType schema: only codexRateLimits is a known banked reset.
        let eligible = (rateLimitResetCredits.credits ?? []).filter {
            $0.status == "available"
                && $0.resetType == "codexRateLimits"
                && ($0.expiresAt.map { $0.isFinite && $0 > now } ?? true)
        }
        let next = eligible.first
        let expiry = next?.expiresAt.map { Date(timeIntervalSince1970: $0) }
        let summary = ResetCredits(
            availableCount: rateLimitResetCredits.availableCount,
            nextID: next?.id,
            nextTitle: next?.title,
            nextExpiry: expiry
        )
        return CodexEligibleCredits(
            summary: summary,
            eligibleCreditIDs: Set(eligible.map(\.id))
        )
    }
}

private struct CodexEligibleCredits {
    let summary: ResetCredits?
    let eligibleCreditIDs: Set<String>

    var availableCount: Int { summary?.availableCount ?? 0 }
}

private struct CodexRateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?

    func quotaWindow(id: String, title: String) throws -> QuotaWindow {
        guard usedPercent.isFinite, (0...100).contains(usedPercent) else {
            throw QuotaError.invalidResponse
        }
        if let resetsAt, !resetsAt.isFinite { throw QuotaError.invalidResponse }
        return QuotaWindow(
            id: id,
            title: title,
            remainingPercent: 100 - usedPercent,
            resetAt: resetsAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

private struct CodexResetCreditsSummary: Decodable {
    let availableCount: Int
    let credits: [CodexResetCredit]?
}

private struct CodexResetCredit: Decodable {
    let id: String
    let resetType: String
    let status: String
    let expiresAt: Double?
    let title: String?
}

private struct CodexRedemptionResponse: Decodable {
    let outcome: String
}

/// Blocking file-handle I/O stays inside this type; `run` isolates it from async callers.
private final class CodexProcessSession: CodexUsageSession, @unchecked Sendable {
    private static let readChunkSize = 8 * 1024
    private static let maximumMessageBytes = 1024 * 1024
    private static let maximumTotalOutputBytes = 4 * 1024 * 1024

    private let lock = NSLock()
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var inputBuffer = Data()
    private var totalOutputBytes = 0
    private var didClose = false

    func start(executable: URL) throws {
        lock.lock()
        let alreadyClosed = didClose
        lock.unlock()
        if alreadyClosed { throw QuotaError.unavailable }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable.standardizedFileURL.resolvingSymlinksInPath()
        process.arguments = ["app-server"]
        // Avoid discovering a project workspace; HOME/CODEX_HOME remain inherited for sign-in.
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try CodexUsage.signatureRequirement.constrain(process)
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw QuotaError.unavailable
        }
        lock.lock()
        let shouldLaunch = !didClose
        lock.unlock()
        guard shouldLaunch else { throw QuotaError.unavailable }

        do {
            try process.run()
        } catch {
            throw QuotaError.unavailable
        }

        lock.lock()
        if didClose {
            lock.unlock()
            Self.closeHandle(input.fileHandleForWriting)
            Self.closeHandle(output.fileHandleForReading)
            Self.stop(process, gracePeriod: 0)
            throw QuotaError.unavailable
        }
        self.process = process
        standardInput = input.fileHandleForWriting
        standardOutput = output.fileHandleForReading
        lock.unlock()
    }

    func send(_ message: [String: Any]) throws {
        lock.lock()
        let input = standardInput
        let closed = didClose
        lock.unlock()
        guard let input, !closed else { throw QuotaError.unavailable }

        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.write(contentsOf: data)
        } catch {
            throw QuotaError.unavailable
        }
    }

    func readMessage() throws -> [String: Any] {
        lock.lock()
        let output = standardOutput
        let closed = didClose
        lock.unlock()
        guard let output, !closed else { throw QuotaError.unavailable }

        while true {
            if let newline = inputBuffer.firstIndex(of: 0x0A) {
                let line = inputBuffer.subdata(in: 0..<newline)
                inputBuffer.removeSubrange(0...newline)
                if line.isEmpty { continue }
                guard
                    let object = try? JSONSerialization.jsonObject(with: line),
                    let message = object as? [String: Any]
                else {
                    throw QuotaError.invalidResponse
                }
                return message
            }

            let data: Data
            do {
                data = try output.read(upToCount: Self.readChunkSize) ?? Data()
            } catch {
                throw QuotaError.unavailable
            }
            if data.isEmpty { throw QuotaError.unavailable }
            totalOutputBytes += data.count
            inputBuffer.append(data)
            if inputBuffer.count > Self.maximumMessageBytes
                || totalOutputBytes > Self.maximumTotalOutputBytes {
                throw QuotaError.invalidResponse
            }
        }
    }

    func close() {
        let resources = takeResources()
        guard let resources else { return }
        Self.closeHandle(resources.input)
        if let process = resources.process { Self.stop(process, gracePeriod: 0.5) }
        Self.closeHandle(resources.output)
    }

    func interrupt() {
        let resources = takeResources()
        guard let resources else { return }
        Self.closeHandle(resources.input)
        Self.closeHandle(resources.output)
        if let process = resources.process { Self.stop(process, gracePeriod: 0) }
    }

    private func takeResources() -> (
        process: Process?,
        input: FileHandle?,
        output: FileHandle?
    )? {
        lock.lock()
        defer { lock.unlock() }
        guard !didClose else { return nil }
        didClose = true
        return (process, standardInput, standardOutput)
    }


    private static func closeHandle(_ handle: FileHandle?) {
        try? handle?.close()
    }

    private static func stop(_ process: Process, gracePeriod: TimeInterval) {
        if waitForExit(process, timeout: gracePeriod) { return }
        if process.isRunning { process.terminate() }
        if waitForExit(process, timeout: gracePeriod == 0 ? 0.1 : 0.5) { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        _ = waitForExit(process, timeout: 0.1)
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }
}
