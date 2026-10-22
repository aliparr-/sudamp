// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Testing
@testable import Picker

/// DESIGN §6.4's breaker schedules under a hand-advanced clock (PLAN M6 `make test`).
@Suite struct BreakerTests {
    let yt1 = stream(.youtube, 1).id, yt2 = stream(.youtube, 2).id, yt3 = stream(.youtube, 3).id
    let sc1 = stream(.soundcloud, 1).id, sc2 = stream(.soundcloud, 2).id

    @Test func botCheckEscalatesSixTwelveTwentyFourThenResets() {
        var b = SourceBreakers()
        var now = t0
        var durations: [TimeInterval] = []
        for i in 0..<5 {
            let e = b.recordFailure(.youtube, stream: yt1, failure: .botCheck, now: now)
            #expect(e.change == .tripped && e.kind == .botCheck, "trip \(i)")
            durations.append(e.duration ?? 0)
            #expect(b.state(.youtube, now: now) == .open)
            #expect(b[.youtube].reopenAt == now.addingTimeInterval(e.duration ?? 0))
            // Just before the reopen it is still open; just after, half-open with one probe allowed.
            #expect(b.state(.youtube, now: now.addingTimeInterval((e.duration ?? 0) - 1)) == .open)
            now = now.addingTimeInterval((e.duration ?? 0) + 1)
            #expect(b.state(.youtube, now: now) == .halfOpen)
            #expect(!b.blocked(now: now).contains(.youtube), "the probe may be picked")
            #expect(b.blocked(now: now, background: true).contains(.youtube), "prefetch and hover never probe")
            b.notePicked(.youtube, stream: yt1, now: now)
            #expect(b.blocked(now: now).contains(.youtube), "one probe at a time")
        }
        let expected: [TimeInterval] = [6, 12, 24, 24, 24].map { $0 * 3600 }
        #expect(durations == expected)
        // The probe succeeds: closed, and the next trip starts at 6 h again.
        let reset = b.recordSuccess(.youtube, stream: yt1, now: now)
        #expect(reset.change == .reset)
        #expect(b.state(.youtube, now: now) == .closed && b.platforms.isEmpty)
        let again = b.recordFailure(.youtube, stream: yt2, failure: .botCheck, now: now)
        #expect(again.duration == TimeInterval(6 * 3600), "\(String(describing: again))")
    }

    @Test func youtubeLiveSharesYouTubesBreaker() {
        var b = SourceBreakers()
        b.recordFailure(.youtubeLive, stream: stream(.youtubeLive, 1).id, failure: .botCheck, now: t0)
        #expect(b.blocked(now: t0) == [.youtube, .youtubeLive])
        #expect(b.state(.youtube, now: t0) == .open)
    }

    @Test func engineBreakerOpensAfterTwoInARowFifteenMinutesToOneHour() {
        var b = SourceBreakers()
        let first = b.recordFailure(.youtube, stream: yt1, failure: .engine, now: t0)
        #expect(first.change == .counted && !first.engineFailuresTripped)
        #expect(b.state(.youtube, now: t0) == .closed)
        let second = b.recordFailure(.youtube, stream: yt2, failure: .engine, now: t0.addingTimeInterval(5))
        #expect(second.change == .tripped && second.kind == .engine && second.engineFailuresTripped)
        var durations = [second.duration ?? 0]
        var now = t0.addingTimeInterval(5)
        for _ in 0..<3 {
            now = now.addingTimeInterval(durations.last! + 1)
            #expect(b.state(.youtube, now: now) == .halfOpen)
            b.notePicked(.youtube, stream: yt3, now: now)
            // One engine failure of the probe re-opens it, one step longer.
            let e = b.recordFailure(.youtube, stream: yt3, failure: .engine, now: now)
            #expect(e.change == .tripped && e.kind == .engine)
            durations.append(e.duration ?? 0)
        }
        let expected: [TimeInterval] = [900, 1800, 3600, 3600]
        #expect(durations == expected)
    }

    @Test func aSuccessBetweenEngineFailuresStartsTheCountAgain() {
        var b = SourceBreakers()
        b.recordFailure(.youtube, stream: yt1, failure: .engine, now: t0)
        b.recordSuccess(.youtube, stream: yt2, now: t0)
        let counted = b.recordFailure(.youtube, stream: yt3, failure: .engine, now: t0)
        #expect(counted.change == .counted)
    }

    @Test func transientBreakerNeedsThreeFailuresOnTwoStreamsInTenMinutes() {
        var b = SourceBreakers()
        // Three failures of one stream: its own backoff handles it, the source stays closed.
        for i in 0..<3 {
            let e = b.recordFailure(.soundcloud, stream: sc1, failure: .transient, now: t0.addingTimeInterval(Double(i)))
            #expect(e.change == .counted)
        }
        #expect(b.state(.soundcloud, now: t0) == .closed)
        // Spread over more than 10 minutes: the window forgets the oldest.
        var c = SourceBreakers()
        c.recordFailure(.soundcloud, stream: sc1, failure: .transient, now: t0)
        c.recordFailure(.soundcloud, stream: sc2, failure: .transient, now: t0.addingTimeInterval(300))
        let late = c.recordFailure(.soundcloud, stream: sc1, failure: .transient, now: t0.addingTimeInterval(601))
        #expect(late.change == .counted)
        // Three within 10 minutes across two streams: open 15 minutes.
        let e = c.recordFailure(.soundcloud, stream: sc2, failure: .transient, now: t0.addingTimeInterval(610))
        #expect(e.change == .tripped && e.kind == .transient && e.duration == TimeInterval(15 * 60))
    }

    @Test func transientScheduleDoublesToTwoHours() {
        var b = SourceBreakers()
        var now = t0
        let ids = [sc1, sc2, sc1]
        var durations: [TimeInterval] = []
        var e = BreakerEvent(platform: .soundcloud, change: .ignored)
        for (i, id) in ids.enumerated() {
            e = b.recordFailure(.soundcloud, stream: id, failure: .transient, now: now.addingTimeInterval(Double(i)))
        }
        durations.append(e.duration ?? 0)
        now = now.addingTimeInterval(10)
        for _ in 0..<5 {
            now = now.addingTimeInterval(durations.last! + 1)
            #expect(b.state(.soundcloud, now: now) == .halfOpen)
            b.notePicked(.soundcloud, stream: sc2, now: now)
            durations.append(b.recordFailure(.soundcloud, stream: sc2, failure: .transient, now: now).duration ?? 0)
        }
        let expected: [TimeInterval] = [15, 30, 60, 120, 120, 120].map { $0 * 60 }
        #expect(durations == expected)
    }

    @Test func unavailableNeverTripsAndFreesTheProbe() {
        var b = SourceBreakers()
        b.recordFailure(.youtube, stream: yt1, failure: .botCheck, now: t0)
        let later = t0.addingTimeInterval(6 * 3600 + 1)
        b.notePicked(.youtube, stream: yt2, now: later)
        #expect(b.blocked(now: later).contains(.youtube))
        let e = b.recordFailure(.youtube, stream: yt2, failure: .unavailable, now: later)
        #expect(e.change == .ignored)
        #expect(b.state(.youtube, now: later) == .halfOpen && !b.blocked(now: later).contains(.youtube),
                "a removed video says nothing about YouTube: the next pick probes again")
        b.notePicked(.youtube, stream: yt3, now: later)
        b.releaseProbe(yt3)
        #expect(!b.blocked(now: later).contains(.youtube))
    }

    @Test func radioHasNoSourceBreaker() {
        var b = SourceBreakers()
        for n in 1...6 {
            let e = b.recordFailure(.radio, stream: stream(.radio, n).id, failure: .transient, now: t0)
            #expect(e.change == .ignored)
        }
        #expect(b.platforms.isEmpty && b.blocked(now: t0).isEmpty)
    }

    @Test func failuresRacingAnOpenBreakerDontEscalate() {
        var b = SourceBreakers()
        let first = b.recordFailure(.youtube, stream: yt1, failure: .botCheck, now: t0)
        #expect(first.duration == TimeInterval(6 * 3600), "\(String(describing: first))")
        // A prefetch that was already in flight reports its own bot check a second later.
        let racing = b.recordFailure(.youtube, stream: yt2, failure: .botCheck, now: t0.addingTimeInterval(1))
        #expect(racing.change == .ignored)
        #expect(b[.youtube].reopenAt == t0.addingTimeInterval(6 * 3600))
        #expect(b[.youtube].trips[.botCheck] == 1)
    }

    @Test func breakersSurviveSessionJSONButProbesDont() throws {
        var b = SourceBreakers()
        b.recordFailure(.youtube, stream: yt1, failure: .botCheck, now: t0)
        b.recordFailure(.mixcloud, stream: stream(.mixcloud, 1).id, failure: .engine, now: t0)
        b.notePicked(.youtube, stream: yt2, now: t0.addingTimeInterval(7 * 3600))
        let url = FileManager.default.temporaryDirectory.appending(path: "breakers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try StateFile.save(SessionFile(picker: PickerState(), breakers: b), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"youtube\"") && text.contains("\"botCheck\"") && text.contains("reopenAt"))
        let loaded = try #require(StateFile.load(SessionFile.self, from: url))
        let restored = try #require(loaded.breakers)
        #expect(restored[.youtube].reopenAt == b[.youtube].reopenAt)
        #expect(restored[.youtube].trips == [.botCheck: 1])
        #expect(restored[.mixcloud].engineFailuresInARow == 1)
        #expect(restored[.youtube].probe == nil, "a relaunch may probe again")
    }

    @Test func sessionFilesWithoutBreakersStillLoad() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "old-session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1,"picker":{"bags":{},"health":{},"revision":2}}"#.utf8).write(to: url)
        let loaded = try #require(StateFile.load(SessionFile.self, from: url))
        #expect(loaded.breakers == nil && loaded.picker.revision == 2)
    }

    @Test func openBreakersMakeStreamsIneligible() {
        var b = SourceBreakers()
        b.recordFailure(.youtube, stream: yt1, failure: .botCheck, now: t0)
        let ctx = PickContext(now: t0, openBreakers: b.blocked(now: t0))
        #expect(Eligibility.reason(stream(.youtube, 9), health: nil, context: ctx) == .breakerOpen)
        #expect(Eligibility.reason(stream(.youtubeLive, 9), health: nil, context: ctx) == .breakerOpen)
        #expect(Eligibility.isEligible(stream(.soundcloud, 9), health: nil, context: ctx))
    }
}
