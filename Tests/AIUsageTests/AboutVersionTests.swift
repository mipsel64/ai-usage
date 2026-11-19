import Testing
@testable import AIUsage

struct AboutVersionTests {
    @Test func versionJoinsTheCommitHashAndNeverInventsOne() {
        #expect(AboutPanel.version(short: "0.1.0", commit: "4fb5b08") == "0.1.0+4fb5b08")
        #expect(AboutPanel.version(short: "0.1.0", commit: nil) == "0.1.0")
        #expect(AboutPanel.version(short: nil, commit: "4fb5b08") == nil)
    }
}
