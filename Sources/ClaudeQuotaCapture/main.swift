import Foundation
import QuotaCore

private let maximumInputBytes = 1024 * 1024

private struct InputProjection {
    let data: Data
    let isOversized: Bool
}

private func readStandardInput(passthrough: Bool) throws -> InputProjection {
    let input = FileHandle.standardInput
    var projection = Data()
    var isOversized = false
    while true {
        let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
        guard !chunk.isEmpty else {
            return InputProjection(data: projection, isOversized: isOversized)
        }
        if passthrough {
            FileHandle.standardOutput.write(chunk)
        }
        let retainedBytes = min(chunk.count, maximumInputBytes - projection.count)
        if retainedBytes > 0 {
            projection.append(chunk.prefix(retainedBytes))
        }
        if retainedBytes < chunk.count {
            isOversized = true
        }
    }
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
let passthrough: Bool
switch arguments {
case []:
    passthrough = false
case ["--passthrough"]:
    passthrough = true
default:
    writeError("Usage: claude-quota-capture [--passthrough]")
    exit(64)
}

do {
    let input = try readStandardInput(passthrough: passthrough)
    if passthrough {
        do {
            guard !input.isOversized else { throw QuotaError.invalidResponse }
            _ = try ClaudeUsage.captureStatusLine(input: input.data)
        } catch {
            writeError("Claude quota capture failed.")
        }
    } else {
        guard !input.isOversized else { throw QuotaError.invalidResponse }
        let status = try ClaudeUsage.captureStatusLine(input: input.data)
        FileHandle.standardOutput.write(Data((status + "\n").utf8))
    }
} catch {
    // Never echo the payload or an error containing input data.
    writeError("Claude quota capture failed.")
    exit(1)
}
