import Foundation
import LightweightCodeRequirements
import Security

public enum ExecutableError: LocalizedError {
    case untrusted
    public var errorDescription: String? { "Select the provider’s signed native executable. Scripts and other publishers are not accepted." }
}

public struct SignedExecutable: Sendable {
    let team: String
    let identifier: String

    public init(team: String, identifier: String) {
        self.team = team
        self.identifier = identifier
    }

    func constrain(_ process: Process) throws {
        process.launchRequirement = try .allOf {
            TeamIdentifier(team)
            SigningIdentifier(identifier)
            ValidationCategory(.developerID)
        }
    }

    public func validate(_ url: URL) throws -> URL {
        let requirement = #"identifier "\#(identifier)" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "\#(team)""#
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ExecutableError.untrusted }
        let path = url.resolvingSymlinksInPath().standardizedFileURL
        var code: SecStaticCode?
        var rule: SecRequirement?
        let flags = SecCSFlags(rawValue: 0)
        guard FileManager.default.isExecutableFile(atPath: path.path),
              SecStaticCodeCreateWithPath(path as CFURL, flags, &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, flags, &rule) == errSecSuccess, let rule,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), rule) == errSecSuccess
        else { throw ExecutableError.untrusted }
        return path
    }
}
