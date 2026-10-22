import Testing
@testable import Shell

@MainActor @Test func shellModuleLinks() {
    #expect(SudampApp.self == SudampApp.self)
}
