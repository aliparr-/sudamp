// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Core

@Suite struct AutomationScriptTests {
    private func parse(_ json: String) throws -> AutomationScript { try AutomationScript.parse(Data(json.utf8)) }

    @Test func parsesEveryStepForm() throws {
        let s = try parse("""
        {"name": "all", "timeout": 7, "steps": [
          {"selectGenre": "deep-house"}, {"selectGenre": "surprise"}, "surpriseMe", {"surpriseMe": true},
          "pressPlay", "pressPause", {"pressPlayPause": true}, "pressNext", "pressPrevious", "pressStop", "pressRetry",
          {"waitFor": "playing"}, {"waitFor": ["playing", "failed"], "timeout": 20, "comment": "either"},
          {"sleep": 1.5}, "dumpState", {"dumpState": "after"}, {"openURL": "sudamp://next"}, {"setVolume": 40},
          {"waitForEngine": "unreachable", "timeout": 4}, {"snapshot": "/tmp/w.png"}
        ]}
        """)
        #expect(s.name == "all")
        #expect(s.steps == [
            .selectGenre("deep-house"), .surpriseMe, .surpriseMe, .surpriseMe, .press(.play), .press(.pause),
            .press(.playPause), .press(.next), .press(.previous), .press(.stop), .press(.retry),
            .waitFor(states: ["playing"], timeout: 7), .waitFor(states: ["playing", "failed"], timeout: 20),
            .sleep(1.5), .dumpState(label: nil), .dumpState(label: "after"), .openURL("sudamp://next"), .setVolume(40),
            .waitForEngine("unreachable", timeout: 4), .snapshot("/tmp/w.png"),
        ])
    }

    @Test func aBareArrayIsAScript() throws {
        let s = try parse(#"[{"selectGenre": "lo-fi"}, {"waitFor": "playing"}]"#)
        #expect(s.steps == [.selectGenre("lo-fi"), .waitFor(states: ["playing"], timeout: AutomationScript.defaultTimeout)])
    }

    @Test func theCommittedNorthStarFixtureParses() throws {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appending(path: "Package.swift").path), dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        let script = try AutomationScript.load(from: dir.appending(path: "Fixtures/automation/northstar-plain.json"))
        #expect(script.steps.first == .selectGenre("deep-house"))
        #expect(script.steps.contains(.waitFor(states: ["playing"], timeout: 15)))
    }

    @Test func skipsAppendDwellNextAndWait() {
        var s = AutomationScript(steps: [.selectGenre("techno")])
        s.appendSkips(2, dwell: 3, timeout: 9)
        #expect(s.steps == [.selectGenre("techno"),
                            .sleep(3), .press(.next), .waitFor(states: ["playing"], timeout: 9),
                            .sleep(3), .press(.next), .waitFor(states: ["playing"], timeout: 9)])
        s.appendSkips(0)
        #expect(s.steps.count == 7)
    }

    @Test(arguments: [
        ("not json", "not JSON"),
        (#"{"steps": []}"#, "no steps"),
        (#"{"name": "x"}"#, "no steps"),
        (#"{"steps": ["dance"]}"#, "unknown step dance"),
        (#"{"steps": [{"waitFor": "bored"}]}"#, "unknown state bored"),
        (#"{"steps": [{"waitFor": "playing", "timeout": -1}]}"#, "bad value for timeout"),
        (#"{"steps": [{"selectGenre": "Deep House"}]}"#, "bad value for selectGenre"),
        (#"{"steps": [{"sleep": "long"}]}"#, "bad value for sleep"),
        (#"{"steps": [{"sleep": true}]}"#, "bad value for sleep"),
        (#"{"steps": [{"setVolume": 101}]}"#, "bad value for setVolume"),
        (#"{"steps": [{"openURL": "https://example.com"}]}"#, "bad value for openURL"),
        (#"{"steps": [{"pressNext": true, "selectGenre": "x"}]}"#, "unknown step"),
        (#"{"steps": [{"pressNext": true, "timeout": 3}]}"#, "bad value for timeout"),
        (#"{"steps": ["pressNext"], "bogus": 1}"#, "unknown key bogus"),
        (#"{"steps": [{"waitForEngine": "no space!"}]}"#, "bad value for waitForEngine"),
        (#"{"steps": [{"snapshot": "/tmp/w.jpg"}]}"#, "bad value for snapshot"),
    ])
    func rejects(_ json: String, _ message: String) {
        do {
            _ = try parse(json)
            Issue.record("accepted \(json)")
        } catch {
            #expect("\(error)".contains(message), "\(json) → \(error)")
        }
    }
}

@Suite struct DebugStateQueryTests {
    private let sample = DebugStateSample(json: Data("""
    {"state": "playing", "genre": "deep-house", "stream": {"id": "radio:x", "tag": "FM"}, "resumed": true, "pid": 42,
     "nowPlaying": {"playbackState": "playing"}, "engine": {"download": "unreachable"}}
    """.utf8))!

    @Test func readsTheFlatKeys() {
        #expect(sample == DebugStateSample(state: "playing", genre: "deep-house", streamID: "radio:x", resumed: true,
                                           pid: 42, nowPlayingState: "playing"))
        #expect(DebugStateSample(json: Data("[]".utf8)) == nil)
    }

    @Test func everyConditionMustHold() {
        #expect(DebugStateQuery(states: ["playing"]).matches(sample))
        #expect(DebugStateQuery(states: ["paused", "playing"], genre: "deep-house").matches(sample))
        #expect(!DebugStateQuery(states: ["paused"]).matches(sample))
        #expect(!DebugStateQuery(states: ["playing"], genre: "techno").matches(sample))
        #expect(DebugStateQuery(streamNot: "radio:y").matches(sample))
        #expect(!DebugStateQuery(streamNot: "radio:x").matches(sample))
        #expect(!DebugStateQuery(streamNot: "radio:x").matches(DebugStateSample(state: "tuning")), "no stream yet")
        #expect(DebugStateQuery(resumed: true, nowPlayingState: "playing").matches(sample))
        #expect(!DebugStateQuery(resumed: false).matches(sample))
    }

    @Test func waitPollsTheFileUntilItMatches() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "state.json")
        try Data(#"{"state": "tuning"}"#.utf8).write(to: file)
        let writer = Task.detached {
            try await Task.sleep(for: .milliseconds(150))
            try Data(#"{"state": "playing", "genre": "lo-fi"}"#.utf8).write(to: file, options: .atomic)
        }
        let (matched, _) = await DebugStateQuery(states: ["playing"]).wait(file: file, timeout: 3, interval: 0.02)
        try await writer.value
        #expect(matched?.genre == "lo-fi")
        let (none, last) = await DebugStateQuery(states: ["paused"]).wait(file: file, timeout: 0.1, interval: 0.02)
        #expect(none == nil && last?.state == "playing")
    }
}
