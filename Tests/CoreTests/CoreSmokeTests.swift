import Testing
@testable import Core

@Test func buildInfoHasVersion() {
    #expect(!BuildInfo.version.isEmpty)
    #expect(BuildInfo.logSubsystem == "app.sudamp")
}
