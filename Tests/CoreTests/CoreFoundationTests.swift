import Foundation
import Testing
@testable import Core

@Test func profilePathsFollowDesignLayout() {
    let p = Paths.profile(URL(filePath: "/tmp/p", directoryHint: .isDirectory))
    #expect(p.sessionFile.path == "/tmp/p/session.json")
    #expect(p.debugState.path == "/tmp/p/debug/state.json")
    #expect(p.metricsFile.path == "/tmp/p/Logs/metrics.jsonl")
    #expect(p.instanceSocket.path == "/tmp/p/instance.sock")
    #expect(p.caches.path == "/tmp/p/Caches")
}

@Test func profileResolvesFromArgumentsThenEnvironment() {
    #expect(Paths.resolve(arguments: ["x", "--profile", "/tmp/a"], environment: [:]).appSupport.path == "/tmp/a")
    #expect(Paths.resolve(arguments: ["x", "--profile=/tmp/b"], environment: [:]).appSupport.path == "/tmp/b")
    #expect(Paths.resolve(arguments: ["x"], environment: ["SUDAMP_HOME": "/tmp/c"]).appSupport.path == "/tmp/c")
    #expect(Paths.resolve(arguments: ["x"], environment: [:]).isProfile == false)
}

@Test func seededRandomIsDeterministic() {
    var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42)
    #expect((0..<100).map { _ in a.next() } == (0..<100).map { _ in b.next() })
    var c = SeededRandom(seed: 7)
    for _ in 0..<1000 { let u = c.unitInterval(); #expect(u >= 0 && u < 1) }
}

@Test func fakeTimeAdvances() {
    let t = FakeTimeSource(Date(timeIntervalSince1970: 100))
    t.advance(by: 3600)
    #expect(t.now.timeIntervalSince1970 == 3700)
}

@Test func metricsWritesJSONLines() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "metrics-\(UUID().uuidString)")
    let log = MetricsLog(url: dir.appending(path: "metrics.jsonl"), time: FakeTimeSource(Date(timeIntervalSince1970: 5)))
    log.record("ttfa", ["ms": 812, "source": "radio"])
    log.record("skip")
    let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    #expect(first?["event"] as? String == "ttfa")
    #expect(first?["ms"] as? Int == 812)
    #expect(first?["ts"] as? Double == 5)
}
