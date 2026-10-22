// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Core

@Suite struct RemoteCommandTests {
    @Test(arguments: [
        ("sudamp://genre/deep-house", RemoteCommand.genre("deep-house")),
        ("sudamp://genre/deep-house/", .genre("deep-house")),
        ("SUDAMP://Genre/Deep-House", .genre("deep-house")),
        ("sudamp:genre/lo-fi", .genre("lo-fi")),
        ("sudamp://genre/techno?from=dock#x", .genre("techno")),
        ("sudamp://toggle", .toggle),
        ("sudamp://next", .next),
        ("sudamp:next", .next),
        ("sudamp://next/", .next),
        ("sudamp://previous", .previous),
        ("sudamp://prev", .previous),
        ("sudamp://quit", .quit),
        ("sudamp://play", .play),
        ("sudamp://pause", .pause),
        ("sudamp://stop", .stop),
        ("sudamp://surprise", .surpriseMe),
        ("sudamp://", .show),
        ("sudamp:", .show),
    ])
    func parses(_ text: String, _ expected: RemoteCommand) {
        #expect(RemoteCommand(string: text) == expected, "\(text)")
    }

    @Test(arguments: [
        "https://genre/deep-house", "sudampx://next", "sudamp://genre", "sudamp://genre/", "sudamp://genre/a/b",
        "sudamp://genre/deep_house", "sudamp://genre/-x", "sudamp://genre/\(String(repeating: "a", count: 33))",
        "sudamp://genre/..%2F..", "sudamp://next/now", "sudamp://launch-missiles", "sudamp://genre/deep%20house",
        "not a url", "",
    ])
    func rejects(_ text: String) {
        #expect(RemoteCommand(string: text) == nil, "\(text)")
    }

    @Test func canonicalURLsRoundTrip() {
        let all: [RemoteCommand] = [.genre("deep-house"), .surpriseMe, .toggle, .play, .pause, .stop, .next, .previous,
                                    .quit, .show]
        for c in all { #expect(RemoteCommand(url: c.url) == c, "\(c)") }
        #expect(RemoteCommand.genre("lo-fi").url.absoluteString == "sudamp://genre/lo-fi")
    }

    @Test func urlsAmongArguments() {
        let args = ["--profile", "/tmp/p", "sudamp://next", "--plain", "SUDAMP://quit", "file.wsz"]
        #expect(RemoteCommand.urls(inArguments: args) == ["sudamp://next", "SUDAMP://quit"])
    }
}

@Suite struct LaunchArgumentsTests {
    @Test func parsesTheAppOptions() throws {
        let a = try LaunchArguments.parse([
            "--plain", "--mute", "--profile", "/tmp/p", "--automation=Fixtures/a.json", "--skips", "5", "--json",
            "--skip-dwell", "3.5", "--feed", "f.json", "--source", "radio,soundcloud", "sudamp://genre/techno",
            "--no-resume",
        ])
        #expect(a.plain && a.mute && a.json && a.noResume)
        #expect(a.profile == "/tmp/p" && a.automation == "Fixtures/a.json" && a.skips == 5 && a.skipDwell == 3.5)
        #expect(a.feed == "f.json" && a.sources == ["radio", "soundcloud"] && a.urls == ["sudamp://genre/techno"])
        #expect(a.unknown.isEmpty)
    }

    @Test func skipsAppKitArgumentsAndReportsUnknownOnes() throws {
        let a = try LaunchArguments.parse(["-NSDocumentRevisionsDebugMode", "YES", "-psn_0_12345", "--frobnicate", "x.wsz"])
        #expect(a.unknown == ["--frobnicate", "x.wsz"])
        #expect(!a.plain && a.urls.isEmpty)
    }

    @Test func rejectsBadValues() {
        #expect(throws: LaunchArgumentsError.missingValue("--profile")) { try LaunchArguments.parse(["--profile"]) }
        #expect(throws: LaunchArgumentsError.badValue("--skips", "lots")) {
            try LaunchArguments.parse(["--automation", "a.json", "--skips", "lots"])
        }
        #expect(throws: LaunchArgumentsError.requiresAutomation("--skips")) { try LaunchArguments.parse(["--skips", "2"]) }
    }

    @Test func muteSources() throws {
        let none = try LaunchArguments.parse([])
        let missing = URL(filePath: "/nonexistent/sudamp-mute-\(UUID().uuidString)")
        #expect(!none.isMuted(environment: [:], sentinel: missing))
        #expect(try LaunchArguments.parse(["--mute"]).isMuted(environment: [:], sentinel: missing))
        #expect(none.isMuted(environment: ["SUDAMP_MUTE": "1"], sentinel: missing))
        #expect(none.isMuted(environment: ["SUDAMP_MUTE": "TRUE"], sentinel: missing))
        #expect(!none.isMuted(environment: ["SUDAMP_MUTE": "0"], sentinel: missing))
        #if DEBUG
        let sentinel = FileManager.default.temporaryDirectory.appending(path: "mute-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: sentinel.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        #expect(none.isMuted(environment: [:], sentinel: sentinel), "debug builds honour the sentinel file")
        #endif
    }
}
