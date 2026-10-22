// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import Testing
@testable import Resolver

/// Every stderr fixture in `Fixtures/ytdlp/stderr/cases.json` lands in its DESIGN §6.4 class (PLAN M1).
@Suite struct ClassifierTests {
    struct Case: Decodable, CustomTestStringConvertible, Sendable {
        var file: String
        var `class`: String
        var reason: String
        var origin: String
        var testDescription: String { file }
    }

    static let cases: [Case] = {
        guard let data = try? Fixture.data("stderr/cases.json") else { return [] }
        return (try? JSONDecoder().decode([Case].self, from: data)) ?? []
    }()

    @Test func fixturesExist() {
        #expect(Self.cases.count >= 28)
        let classes = Set(Self.cases.map(\.class))
        #expect(classes == Set(ResolveFailureClass.allCases.map(\.rawValue)))
    }

    @Test(arguments: cases)
    func classifies(_ c: Case) throws {
        let stderr = try Fixture.text("stderr/\(c.file)")
        let f = ResolveErrorClassifier.classify(stderr: stderr, termination: .exited(1), timedOut: false)
        #expect(f.failureClass.rawValue == c.class)
        #expect(f.reason == c.reason)
    }

    @Test func timeoutWinsOverOutput() {
        let f = ResolveErrorClassifier.classify(stderr: "ERROR: Video unavailable", termination: .signaled(9),
                                                timedOut: true, tier: 2, elapsedMs: 12_001)
        #expect(f == ResolveFailure(.transient, "timeout", message: "killed after 12001 ms", tier: 2, elapsedMs: 12_001))
    }

    @Test func errorLineAndWarnings() {
        let s = "[youtube] x\nWARNING: one\nERROR: first\nWARNING: two\nERROR: last\n"
        #expect(ResolveErrorClassifier.errorLine(s) == "ERROR: last")
        #expect(ResolveErrorClassifier.warnings(s) == ["WARNING: one", "WARNING: two"])
        #expect(ResolveErrorClassifier.errorLine("plain\n\n") == "plain")
    }

    @Test func curlyApostropheIsNormalised() {
        let f = ResolveErrorClassifier.classify(stderr: "ERROR: [youtube] x: Sign in to confirm you\u{2019}re not a bot",
                                                termination: .exited(1), timedOut: false)
        #expect(f.failureClass == .botCheck)
    }
}
