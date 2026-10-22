// SPDX-License-Identifier: GPL-3.0-or-later
// libmpv + pull AO end to end, without AVAudioEngine: the test thread pulls sudamp_ao_read in real time, the way
// the render callback would (PLAN M0/M1 "MPVTests pulling sudamp_ao_read"). Serialized: the AO is process-global.
import Foundation
import Testing
import SudampAO
@testable import MPV

/// Pulls 512-frame quanta at the real-time rate and decodes the ramp fixture's position.
final class Puller {
    static let quantum = 512
    private var left = [Float](repeating: 0, count: quantum)
    private var right = [Float](repeating: 0, count: quantum)

    struct Tick {
        var got: Int
        var firstR: Float
        var peak: Float
        var position: Double { RampFixture.position(fromRight: firstR) }
        var audible: Bool { got > 0 && peak > 0 }
    }

    func pull() -> Tick {
        usleep(10_667)
        let got = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                Int(sudamp_ao_read(l.baseAddress!, r.baseAddress!, Int32(Self.quantum), 12_000_000))
            }
        }
        if got < 0 { return Tick(got: got, firstR: 0, peak: 0) }
        let peak = left.prefix(max(got, 0)).reduce(Float(0)) { max($0, abs($1)) }
        return Tick(got: got, firstR: got > 0 ? right[0] : 0, peak: peak)
    }

    /// Pulls until `condition` holds; returns the ticks pulled (the last one satisfied it) or nil on timeout.
    func pull(until condition: (Tick) -> Bool, maxTicks: Int) -> [Tick]? {
        var ticks: [Tick] = []
        for _ in 0..<maxTicks {
            let t = pull()
            ticks.append(t)
            if condition(t) { return ticks }
        }
        return nil
    }
}

enum Fixture {
    static let ramp: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "sudamp-mpvtests/ramp60.wav")
        try! RampFixture.ensure(at: url)
        return url
    }()
}

func makeClient(logLevel: String = "warn") throws -> MPVClient {
    try MPVClient(options: MPVOptions.defaults, logLevel: logLevel)
}

@Suite(.serialized) struct MPVPlaybackTests {
    @Test func everyDesignOptionIsAcceptedAndVersionGuardHolds() throws {
        let client = try makeClient()
        defer { client.shutdown() }
        let rejected = client.optionResults.filter { !$0.ok }.map { "\($0.name)=\($0.value)" }
        #expect(rejected.isEmpty, "rejected: \(rejected)")
        #expect(client.mpvVersion?.hasPrefix(EngineGuards.versionPrefix) == true, "\(client.mpvVersion ?? "nil")")
    }

    @Test func builtinScriptListMatchesRuntimeOptions() throws {
        let client = try makeClient()
        defer { client.shutdown() }
        let all = Set(client.getNode("options")?.array?.compactMap(\.string) ?? [])
        #expect(all.contains("osc") && all.contains("ytdl"))
        // Every load-* option except these non-script ones toggles a built-in script.
        let nonScript: Set = ["load-scripts", "load-unsafe-playlists", "load-osd-console"]
        let runtime = all.filter { $0.hasPrefix("load-") }.subtracting(nonScript)
        let ours = Set(MPVOptions.builtinScriptOptions.filter { $0.hasPrefix("load-") })
        #expect(runtime == ours, "runtime load-* options: \(runtime.sorted())")
    }

    @Test func loadfileStartsPullAOAndPassesGuards() throws {
        let initsBefore = PullAO.initCount
        let client = try makeClient()
        defer { client.shutdown() }
        try client.loadfile(Fixture.ramp.path)
        let puller = Puller()
        let ticks = try #require(puller.pull(until: { $0.audible }, maxTicks: 200), "no audio within ~2 s")
        #expect(PullAO.initCount > initsBefore)
        // Positions advance in real time.
        let a = ticks.last!.position
        _ = puller.pull(until: { _ in false }, maxTicks: 20)
        let b = puller.pull().position
        #expect(b > a + 0.15 && b < a + 0.35, "\(a) → \(b)")
        let guards = client.guards()
        #expect(guards.audioOutParams?.isPullAOFormat == true, "\(String(describing: guards.audioOutParams))")
        #expect(client.audioParams?.samplerate == 44100) // the decoder output; mpv resampled to 48 kHz for us
        #expect(guards.ok, "\(guards.failures)")
        #expect(PullAO.errorCount == 0)
    }

    @Test func pauseSilencesAndResumesContinuously() throws {
        let client = try makeClient()
        defer { client.shutdown() }
        try client.loadfile(Fixture.ramp.path)
        let puller = Puller()
        _ = try #require(puller.pull(until: { $0.audible }, maxTicks: 200))
        _ = puller.pull(until: { _ in false }, maxTicks: 10)
        try client.setPause(true)
        let toSilence = try #require(puller.pull(until: { !$0.audible }, maxTicks: 10), "still audible 100 ms after pause")
        let lastAudible = toSilence.dropLast().last { $0.audible }
        // Stays silent while paused.
        for _ in 0..<10 { #expect(!puller.pull().audible) }
        try client.setPause(false)
        let resumed = try #require(puller.pull(until: { $0.audible }, maxTicks: 20), "no audio 200 ms after unpause")
        if let before = lastAudible {
            let gap = resumed.last!.position - before.position
            #expect(gap > 0 && gap < 0.05, "source gap across pause \(gap) s")
        }
        #expect(client.snapshot.pause == false)
    }

    @Test func seekDeliversNewAudioWithAtMostOneStaleQuantum() throws {
        let client = try makeClient()
        defer { client.shutdown() }
        try client.loadfile(Fixture.ramp.path)
        let puller = Puller()
        _ = try #require(puller.pull(until: { $0.audible }, maxTicks: 200))
        _ = puller.pull(until: { _ in false }, maxTicks: 10)
        for target in [40.0, 12.0, 50.0] {
            try client.seek(to: target)
            let ticks = try #require(puller.pull(until: { $0.audible && abs($0.position - target) < 0.3 }, maxTicks: 30),
                                     "no audio near \(target) s within ~320 ms")
            let stale = ticks.dropLast().filter { $0.audible }.count
            #expect(stale <= 1, "seek \(target): \(stale) stale quanta")
            _ = puller.pull(until: { _ in false }, maxTicks: 5)
        }
    }

    @Test func loadfileReplaceAppliesPerFileOptions() throws {
        let client = try makeClient()
        defer { client.shutdown() }
        try client.loadfile(Fixture.ramp.path)
        let puller = Puller()
        _ = try #require(puller.pull(until: { $0.audible }, maxTicks: 200))
        try client.loadfile(Fixture.ramp.path, options: LoadFileOptions(mediaTitle: "sudamp test", start: 20))
        let ticks = try #require(puller.pull(until: { $0.audible && abs($0.position - 20) < 0.3 }, maxTicks: 60),
                                 "replace with start=20 not heard within ~640 ms")
        #expect(ticks.dropLast().filter { $0.audible }.count <= 1)
        _ = puller.pull(until: { _ in false }, maxTicks: 5)
        #expect(client.snapshot.mediaTitle == "sudamp test")
        #expect(PullAO.errorCount == 0)
    }

    @Test func asyncRequestsReply() async throws {
        let client = try makeClient()
        defer { client.shutdown() }
        let ok = await client.request(["set", "volume", "100"])
        #expect(ok.ok)
        let bad = await client.request(["no-such-command"])
        #expect(!bad.ok)
        let prop = await client.request(node: .array([.string("expand-text"), .string("${mpv-version}")]))
        #expect(prop.result.string?.hasPrefix("mpv v0.41.") == true)
    }

    @Test func shutdownIsOrderedIdempotentAndFinal() throws {
        for i in 0..<3 {
            let client = try makeClient()
            try client.loadfile(Fixture.ramp.path)
            if i > 0 {
                let puller = Puller()
                _ = puller.pull(until: { $0.audible }, maxTicks: 200)
            }
            client.shutdown()
            client.shutdown()
            #expect(client.isShutDown)
            #expect(client.getString("mpv-version") == nil)
            #expect(throws: MPVError.shutDown) { try client.setPause(true) }
        }
        // With mpv gone the AO is uninitialised: reads are refused, not crashing.
        var l = [Float](repeating: 1, count: 8), r = [Float](repeating: 1, count: 8)
        #expect(sudamp_ao_read(&l, &r, 8, 0) == -1)
    }
}
