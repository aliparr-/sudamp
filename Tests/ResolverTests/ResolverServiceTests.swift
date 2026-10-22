// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Synchronization
import Testing
@testable import Resolver

/// A programmable stand-in for yt-dlp, so the service is tested without the network.
final class FakeRunner: Sendable {
    struct Script: Sendable {
        var delay: Duration = .zero
        var result: SubprocessResult
    }

    private let scripts: Mutex<[String: Script]>
    let calls = Mutex<[SubprocessSpec]>([])
    let running = Mutex(0)
    let maxRunning = Mutex(0)

    init(_ scripts: [String: Script]) { self.scripts = Mutex(scripts) }

    /// Keyed by the URL (the last argv element).
    func run(_ spec: SubprocessSpec) async throws -> SubprocessResult {
        calls.withLock { $0.append(spec) }
        let n = running.withLock { $0 += 1; return $0 }
        maxRunning.withLock { $0 = max($0, n) }
        defer { running.withLock { $0 -= 1 } }
        let script = scripts.withLock { $0[spec.arguments.last ?? ""] }!
        try await Task.sleep(for: script.delay)  // throws CancellationError when the task is cancelled
        return script.result
    }

    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static func ok(_ object: [String: Any], delay: Duration = .zero, stderr: String = "") -> Script {
        Script(delay: delay, result: SubprocessResult(termination: .exited(0), stdout: json(object),
                                                      stderr: Data(stderr.utf8), elapsed: .milliseconds(420)))
    }

    static func fail(_ stderr: String, timedOut: Bool = false) -> Script {
        Script(result: SubprocessResult(termination: timedOut ? .signaled(9) : .exited(1), stderr: Data(stderr.utf8),
                                        timedOut: timedOut, elapsed: .milliseconds(80)))
    }
}

@Suite struct ResolverServiceTests {
    let layout = EngineLayout(paths: .profile(FileManager.default.temporaryDirectory
        .appending(path: "resolver-\(UUID().uuidString)")))
    let engine = URL(filePath: "/nonexistent/yt-dlp_macos")
    static let sc = "https://soundcloud.com/someone/a-mix"
    static let yt = "https://www.youtube.com/watch?v=AAAAAAAAAAA"
    static let mc = "https://www.mixcloud.com/someone/a-mix/"

    static var scJSON: [String: Any] { [
        "id": "123", "title": "A Mix", "uploader": "Someone", "duration": 3600.5, "live_status": "not_live",
        "webpage_url": sc, "format_id": "hls_aac_160k", "protocol": "m3u8_native", "ext": "m4a", "acodec": "mp4a.40.2",
        "abr": 160, "url": "https://playback.media-streaming.soundcloud.cloud/x/aac_160k/y/playlist.m3u8?expires=1800003600&Policy=p",
        "http_headers": ["User-Agent": "Mozilla/5.0 test", "Accept": "*/*"],
    ] }

    private func service(_ runner: FakeRunner, qjs: URL? = nil, metrics: MetricsLog? = nil) -> ResolverService {
        ResolverService(layout: layout, engine: engine, qjs: qjs, time: FakeTimeSource(Date(timeIntervalSince1970: 1_800_000_000)),
                        metrics: metrics, runner: { try await runner.run($0) })
    }

    @Test func successParsesTheStream() async throws {
        defer { try? FileManager.default.removeItem(at: layout.home.deletingLastPathComponent()) }
        let runner = FakeRunner([Self.sc: FakeRunner.ok(Self.scJSON, stderr: "WARNING: something odd\n")])
        let metricsURL = layout.home.deletingLastPathComponent().appending(path: "Logs/metrics.jsonl")
        let out = try await service(runner, metrics: MetricsLog(url: metricsURL))
            .resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!))
        let s = out.stream
        #expect(s.url.host == "playback.media-streaming.soundcloud.cloud")
        #expect(s.userAgent == "Mozilla/5.0 test")
        #expect(s.httpHeaders["Accept"] == "*/*")
        #expect(s.expiresAt == 1_800_003_600)
        #expect(s.resolvedAt == 1_800_000_000)
        #expect(s.isHLS)
        #expect(s.abr == 160)
        #expect(s.formatID == "hls_aac_160k")
        #expect(out.warnings == ["WARNING: something odd"])
        #expect(out.elapsedMs == 420)
        let line = try String(contentsOf: metricsURL, encoding: .utf8)
        #expect(line.contains(#""event":"resolve""#) && line.contains(#""source":"soundcloud""#) && line.contains(#""ok":true"#))
        // The fake saw the real argv and the scrubbed environment.
        let spec = try #require(runner.calls.withLock { $0.first })
        #expect(spec.environment["YTDLP_NO_PLUGINS"] == "1")
        #expect(spec.arguments.suffix(2) == ["--", Self.sc])
        #expect(spec.timeout == .seconds(10))
    }

    @Test func failuresAreClassified() async throws {
        let runner = FakeRunner([
            Self.mc: FakeRunner.fail("ERROR: [mixcloud] someone_a-mix: You have reached your play limit for this track\n"),
            Self.yt: FakeRunner.fail("", timedOut: true),
        ])
        let svc = service(runner)
        await #expect(throws: ResolveFailure(.unavailable, "mixcloudRepeatPlay",
                                             message: "ERROR: [mixcloud] someone_a-mix: You have reached your play limit for this track",
                                             tier: 1, elapsedMs: 80)) {
            try await svc.resolve(ResolveRequest(source: .mixcloud, url: URL(string: Self.mc)!))
        }
        do {
            _ = try await svc.resolve(ResolveRequest(source: .youtube, url: URL(string: Self.yt)!))
            Issue.record("expected a failure")
        } catch let f as ResolveFailure {
            #expect(f.failureClass == .transient)
            #expect(f.reason == "timeout")
        }
    }

    @Test func mediaHostOutsideTheAllowlistIsAnEngineFailure() async throws {
        var json = Self.scJSON
        json["url"] = "https://evil.example.net/playlist.m3u8"
        let svc = service(FakeRunner([Self.sc: FakeRunner.ok(json)]))
        do {
            _ = try await svc.resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!))
            Issue.record("expected a failure")
        } catch let f as ResolveFailure {
            #expect(f.failureClass == .engine)
            #expect(f.reason == "mediaHost")
        }
    }

    @Test func previewOnlyIsUnavailable() async throws {
        var json = Self.scJSON
        json["format_id"] = "hls_aac_160k_preview"
        let svc = service(FakeRunner([Self.sc: FakeRunner.ok(json)]))
        do {
            _ = try await svc.resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!))
            Issue.record("expected a failure")
        } catch let f as ResolveFailure {
            #expect(f.failureClass == .unavailable)
            #expect(f.reason == "preview")
        }
    }

    @Test func badJSONIsAnEngineFailure() async throws {
        let script = FakeRunner.Script(result: SubprocessResult(termination: .exited(0), stdout: Data("nope".utf8)))
        let svc = service(FakeRunner([Self.sc: script]))
        do {
            _ = try await svc.resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!))
            Issue.record("expected a failure")
        } catch let f as ResolveFailure {
            #expect(f.reason == "badJSON")
        }
    }

    @Test func refusesRadioAndMissingEngine() async throws {
        let svc = service(FakeRunner([:]))
        await #expect(throws: ResolverError.notResolvable(.radio)) {
            try await svc.resolve(ResolveRequest(source: .radio, url: URL(string: "https://radio.example.com/s")!))
        }
        await svc.setEngine(nil)
        await #expect(throws: ResolverError.engineMissing) {
            try await svc.resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!))
        }
    }

    @Test func resolvesOneAtATime() async throws {
        let runner = FakeRunner([Self.sc: FakeRunner.ok(Self.scJSON, delay: .milliseconds(50))])
        let svc = service(runner)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await svc.resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!)) }
            }
            try await group.waitForAll()
        }
        #expect(runner.calls.withLock { $0.count } == 5)
        #expect(runner.maxRunning.withLock { $0 } == 1)
    }

    @Test func userPickPreemptsBackgroundResolve() async throws {
        let runner = FakeRunner([
            Self.yt: FakeRunner.ok([:], delay: .seconds(30)),
            Self.sc: FakeRunner.ok(Self.scJSON),
        ])
        let svc = service(runner)
        let started = ContinuousClock.now
        let prefetch = Task {
            try await svc.resolve(ResolveRequest(source: .youtube, url: URL(string: Self.yt)!), priority: .background)
        }
        try await Task.sleep(for: .milliseconds(100))
        let pick = try await svc.resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!))
        #expect(pick.stream.title == "A Mix")
        await #expect(throws: ResolverError.preempted) { try await prefetch.value }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func backgroundDoesNotPreemptAUserPick() async throws {
        let runner = FakeRunner([
            Self.sc: FakeRunner.ok(Self.scJSON, delay: .milliseconds(300)),
            Self.mc: FakeRunner.ok(["url": "https://aod.mixcloud.stream/x.m3u8"]),
        ])
        let svc = service(runner)
        let user = Task { try await svc.resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!)) }
        try await Task.sleep(for: .milliseconds(50))
        let bg = try await svc.resolve(ResolveRequest(source: .mixcloud, url: URL(string: Self.mc)!), priority: .background)
        #expect(bg.stream.url.host == "aod.mixcloud.stream")
        #expect(try await user.value.stream.title == "A Mix")
        // The user pick ran first and finished before the queued background resolve started.
        #expect(runner.calls.withLock { $0.map { $0.arguments.last! } } == [Self.sc, Self.mc])
    }

    @Test func cancellingTheCallerCancelsTheRun() async throws {
        let runner = FakeRunner([Self.yt: FakeRunner.ok([:], delay: .seconds(30))])
        let svc = service(runner)
        let task = Task { try await svc.resolve(ResolveRequest(source: .youtube, url: URL(string: Self.yt)!)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(runner.running.withLock { $0 } == 0)
    }

    @Test func cancelledWaiterLeavesTheQueue() async throws {
        let runner = FakeRunner([
            Self.sc: FakeRunner.ok(Self.scJSON, delay: .milliseconds(300)),
            Self.mc: FakeRunner.ok(["url": "https://aod.mixcloud.stream/x.m3u8"]),
        ])
        let svc = service(runner)
        let first = Task { try await svc.resolve(ResolveRequest(source: .soundcloud, url: URL(string: Self.sc)!)) }
        try await Task.sleep(for: .milliseconds(50))
        let waiting = Task { try await svc.resolve(ResolveRequest(source: .mixcloud, url: URL(string: Self.mc)!)) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        _ = try await first.value
        #expect(runner.calls.withLock { $0.count } == 1)
    }

    @Test func ladderStepsUpOnEngineFailuresOnly() async throws {
        let qjs = URL(filePath: "/opt/qjs")
        let failing = FakeRunner([Self.yt: FakeRunner.fail("ERROR: [youtube] AAAAAAAAAAA: Requested format is not available\n")])
        await #expect(throws: ResolveFailure.self) {
            try await service(failing, qjs: qjs).resolveWithLadder(ResolveRequest(source: .youtube, url: URL(string: Self.yt)!))
        }
        let tiers = failing.calls.withLock { $0.map { $0.arguments.contains("quickjs:/opt/qjs") } }
        #expect(tiers == [false, true])

        let botCheck = FakeRunner([Self.yt: FakeRunner.fail("ERROR: [youtube] x: Sign in to confirm you're not a bot\n")])
        await #expect(throws: ResolveFailure.self) {
            try await service(botCheck, qjs: qjs).resolveWithLadder(ResolveRequest(source: .youtube, url: URL(string: Self.yt)!))
        }
        #expect(botCheck.calls.withLock { $0.count } == 1, "a bot-check must not burn a second YouTube request")
    }
}

@Suite struct ResolvedStreamTests {
    @Test func expiryFromQueryAndPath() {
        #expect(ResolvedStream.expiry(of: URL(string: "https://rr1.googlevideo.com/videoplayback?expire=1792693545&ei=x")!)
            == 1_792_693_545)
        #expect(ResolvedStream.expiry(of: URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/expire/1792693545/ei/x/index.m3u8")!)
            == 1_792_693_545)
        #expect(ResolvedStream.expiry(of: URL(string: "https://a.sndcdn.com/p.m3u8?expires=1792680000")!) == 1_792_680_000)
        #expect(ResolvedStream.expiry(of: URL(string: "https://aod.mixcloud.stream/secure/hls/x.m3u8")!) == nil)
        #expect(ResolvedStream.expiry(of: URL(string: "https://a.example/x?expire=12")!) == nil)
    }

    @Test func mediaHostAllowlist() {
        let hosts = ["googlevideo.com"]
        #expect(ResolvedStream.isAllowedMediaHost(URL(string: "https://rr3---sn-abc.googlevideo.com/v")!, suffixes: hosts))
        #expect(ResolvedStream.isAllowedMediaHost(URL(string: "https://googlevideo.com/v")!, suffixes: hosts))
        #expect(!ResolvedStream.isAllowedMediaHost(URL(string: "http://rr3.googlevideo.com/v")!, suffixes: hosts))
        #expect(!ResolvedStream.isAllowedMediaHost(URL(string: "https://evilgooglevideo.com/v")!, suffixes: hosts))
        #expect(!ResolvedStream.isAllowedMediaHost(URL(string: "https://googlevideo.com.evil.net/v")!, suffixes: hosts))
        #expect(!ResolvedStream.isAllowedMediaHost(URL(string: "https://u@rr3.googlevideo.com/v")!, suffixes: hosts))
    }

    @Test func mergedSelectionUsesTheAudioFormat() throws {
        let json = FakeRunner.json(["requested_formats": [
            ["url": "https://rr1.googlevideo.com/video", "acodec": "none", "format_id": "137"],
            ["url": "https://rr1.googlevideo.com/audio", "acodec": "opus", "format_id": "251"],
        ], "title": "t"])
        let s = try ResolvedStream.parse(json: json, source: .youtube, tier: 1, now: Date())
        #expect(s.formatID == "251")
    }

    @Test func availableAtWaitIsRelativeToNow() throws {
        let json = FakeRunner.json(["url": "https://rr1.googlevideo.com/a", "available_at": 1_800_000_020])
        let s = try ResolvedStream.parse(json: json, source: .youtube, tier: 2, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(s.wait(now: Date(timeIntervalSince1970: 1_800_000_000)) == 20)
        #expect(s.wait(now: Date(timeIntervalSince1970: 1_800_000_030)) == 0)
    }

    @Test func roundTripsThroughJSON() throws {
        let json = FakeRunner.json(ResolverServiceTests.scJSON)
        let s = try ResolvedStream.parse(json: json, source: .soundcloud, tier: 1, now: Date(timeIntervalSince1970: 5))
        let back = try JSONDecoder().decode(ResolvedStream.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
