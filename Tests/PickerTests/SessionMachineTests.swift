// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Testing
@testable import Picker

private let yt = stream(.youtube, 1), sc = stream(.soundcloud, 1), radio = stream(.radio, 1)

/// Applies events in order, returning the final state and each step's effects.
private func run(_ events: [SessionEvent], from start: SessionState = SessionState()) -> (SessionState, [[SessionEffect]]) {
    var s = start
    var all: [[SessionEffect]] = []
    for e in events {
        let (next, effects) = SessionMachine.reduce(s, e)
        s = next
        all.append(effects)
    }
    return (s, all)
}

private func state(_ phase: PlaybackPhase, current: StreamRef? = yt, awaitingPick: Bool = false) -> SessionState {
    var s = SessionState()
    s.phase = phase
    s.genre = deep
    s.current = current
    s.awaitingPick = awaitingPick
    if phase == .offline { s.resumePhase = .tuning }
    return s
}

@Test func northStarFlowThroughResolve() {
    let (s, fx) = run([.selectGenre(deep), .picked(deep, yt), .resolved(yt.id), .started(yt.id)])
    #expect(fx[0] == [.pick(deep, fastStart: true), .persist])
    #expect(fx[1] == [.resolve(yt), .flash(.tuning)])
    #expect(fx[2] == [.load(yt)])
    #expect(fx[3] == [.recordOutcome(yt.id, .success), .nowPlaying(.playing, yt), .persist, .prefetch(deep)])
    #expect(s.phase == .playing && s.current == yt && s.genre == deep && s.failuresInARow == 0)
}

@Test func radioSkipsTheResolver() {
    let (s, fx) = run([.selectGenre(deep), .picked(deep, radio)])
    #expect(fx[1] == [.load(radio)])
    #expect(s.phase == .buffering)
}

@Test func pauseResumeAndToggle() {
    var (s, fx) = run([.pause], from: state(.playing))
    #expect(s.phase == .paused && fx[0] == [.pause(true), .nowPlaying(.paused, yt), .persist])
    (s, fx) = run([.play], from: s)
    #expect(s.phase == .playing && fx[0] == [.pause(false), .nowPlaying(.playing, yt), .persist])
    (s, _) = run([.togglePause], from: s)
    #expect(s.phase == .paused)
    (s, _) = run([.togglePause], from: s)
    #expect(s.phase == .playing)
}

@Test func nextAndEndOfFileAdvanceWithoutCountingFailures() {
    var start = state(.playing)
    start.failuresInARow = 2
    var (s, fx) = run([.next], from: start)
    #expect(s.phase == .tuning && s.awaitingPick && s.current == nil && s.failuresInARow == 0)
    #expect(fx[0] == [.pick(deep, fastStart: false)])
    (s, fx) = run([.endOfFile(yt.id)], from: state(.playing))
    #expect(s.phase == .tuning && fx[0] == [.pick(deep, fastStart: false)])
    (s, _) = run([.next], from: state(.paused))
    #expect(s.phase == .tuning)
}

@Test func failureAutoAdvances() {
    let (s, fx) = run([.resolveFailed(yt.id, .unavailable)], from: state(.tuning))
    #expect(fx[0] == [.recordOutcome(yt.id, .failure(.unavailable)), .flash(.skipping), .pick(deep, fastStart: false)])
    #expect(s.phase == .tuning && s.awaitingPick && s.failuresInARow == 1)
    let (s2, fx2) = run([.playbackFailed(yt.id, .transient)], from: state(.playing))
    #expect(fx2[0] == [.recordOutcome(yt.id, .failure(.transient)), .flash(.skipping), .pick(deep, fastStart: false)])
    #expect(s2.phase == .tuning)
}

@Test func fiveFailuresInARowStopThenRetry() {
    var s = run([.selectGenre(deep)]).0
    var last: [SessionEffect] = []
    for i in 1...5 {
        let id = stream(.soundcloud, i)
        let (n, fx) = run([.picked(deep, id), .resolveFailed(id.id, .transient)], from: s)
        s = n
        last = fx[1]
        if i < 5 { #expect(s.phase == .tuning && s.failuresInARow == i) }
    }
    #expect(s.phase == .failed && s.current == nil)
    #expect(last == [.recordOutcome(stream(.soundcloud, 5).id, .failure(.transient)), .stop, .flash(.cantReachStreams),
                     .nowPlaying(.failed, nil), .persist])
    #expect(FlashMessage.cantReachStreams.text == "CAN'T REACH STREAMS - CLICK TO RETRY")
    let (r, fx) = run([.retry], from: s)
    #expect(r.phase == .tuning && r.failuresInARow == 0 && fx[0] == [.pick(deep, fastStart: true)])
}

@Test func aSuccessResetsTheFailureCount() {
    var s = run([.selectGenre(deep)]).0
    for i in 1...4 { s = run([.picked(deep, stream(.soundcloud, i)), .resolveFailed(stream(.soundcloud, i).id, .transient)], from: s).0 }
    #expect(s.failuresInARow == 4)
    s = run([.picked(deep, radio), .started(radio.id)], from: s).0
    #expect(s.phase == .playing && s.failuresInARow == 0)
    s = run([.playbackFailed(radio.id, .transient)], from: s).0
    #expect(s.phase == .tuning && s.failuresInARow == 1)
}

@Test func nothingEligibleFails() {
    let (s, fx) = run([.selectGenre(deep), .picked(deep, nil)])
    #expect(s.phase == .failed)
    #expect(fx[1] == [.stop, .flash(.cantReachStreams), .nowPlaying(.failed, nil), .persist])
}

@Test func staleEventsAreIgnored() {
    let tuning = run([.selectGenre(deep), .picked(deep, yt)]).0
    for e: SessionEvent in [.resolved(sc.id), .resolveFailed(sc.id, .transient), .started(yt.id), .picked(deep, sc),
                            .picked(techno, sc), .endOfFile(yt.id), .playbackFailed(yt.id, .engine)] {
        let (s, fx) = SessionMachine.reduce(tuning, e)
        #expect(s == tuning && fx.isEmpty, "\(e)")
    }
    // After the user skips, the old stream's late results are ignored.
    let skipped = run([.next], from: state(.playing)).0
    for e: SessionEvent in [.resolved(yt.id), .resolveFailed(yt.id, .transient), .started(yt.id), .playbackFailed(yt.id, .transient)] {
        #expect(SessionMachine.reduce(skipped, e).0 == skipped, "\(e)")
    }
    // A pick answer for a genre the user already left is ignored too.
    let switched = run([.selectGenre(deep), .selectGenre(techno)]).0
    #expect(SessionMachine.reduce(switched, .picked(deep, yt)).0 == switched)
}

@Test func stopAndResume() {
    var (s, fx) = run([.stop], from: state(.playing))
    #expect(s.phase == .idle && s.current == nil && s.genre == deep)
    #expect(fx[0] == [.stop, .nowPlaying(.idle, nil), .persist])
    #expect(run([.stop], from: s).1[0].isEmpty)
    (s, fx) = run([.play], from: s)
    #expect(s.phase == .tuning && fx[0] == [.pick(deep, fastStart: true)])
    #expect(run([.play, .next]).0.phase == .idle, "no genre yet: nothing to play")
}

@Test func offlineAndBack() {
    var (s, fx) = run([.networkLost], from: state(.playing))
    #expect(s.phase == .offline && fx[0] == [.flash(.offline), .nowPlaying(.offline, yt)])
    // Failures while offline are the network's fault: not counted, no skipping.
    #expect(run([.resolveFailed(yt.id, .transient), .playbackFailed(yt.id, .transient), .next], from: s).0 == s)
    (s, fx) = run([.networkRestored], from: s)
    #expect(s.phase == .tuning && fx[0] == [.resolve(yt), .flash(.tuning)])

    (s, fx) = run([.networkLost, .networkRestored], from: state(.playing, current: radio))
    #expect(s.phase == .buffering && fx[1] == [.load(radio)])

    (s, _) = run([.networkLost, .networkRestored], from: state(.paused))
    #expect(s.phase == .paused)

    (s, fx) = run([.selectGenre(deep), .networkLost, .networkRestored])
    #expect(s.phase == .tuning && fx[2] == [.pick(deep, fastStart: true)])

    // Picking another genre while offline takes effect when the network returns.
    (s, fx) = run([.networkLost, .selectGenre(techno), .networkRestored], from: state(.playing))
    #expect(fx[1] == [.flash(.offline), .persist])
    #expect(s.genre == techno && s.phase == .tuning && fx[2] == [.pick(techno, fastStart: true)])

    #expect(run([.networkLost]).0.phase == .idle)
}

/// Every (phase, event) pair, by resulting phase.
@Test func transitionMatrix() {
    let events: [(String, SessionEvent)] = [
        ("select", .selectGenre(techno)), ("next", .next), ("play", .play), ("pause", .pause), ("toggle", .togglePause),
        ("stop", .stop), ("retry", .retry), ("picked", .picked(deep, sc)), ("pickedNil", .picked(deep, nil)),
        ("resolved", .resolved(yt.id)), ("resolveFailed", .resolveFailed(yt.id, .transient)), ("started", .started(yt.id)),
        ("eof", .endOfFile(yt.id)), ("playbackFailed", .playbackFailed(yt.id, .transient)),
        ("lost", .networkLost), ("restored", .networkRestored), ("playStream", .playStream(sc)),
        ("deferred", .resolveDeferred(yt.id)), ("reload", .reloadCurrent),
    ]
    typealias Row = [String: PlaybackPhase]
    let I = PlaybackPhase.idle, T = PlaybackPhase.tuning, B = PlaybackPhase.buffering, P = PlaybackPhase.playing,
        Z = PlaybackPhase.paused, O = PlaybackPhase.offline, F = PlaybackPhase.failed
    let matrix: [(SessionState, Row)] = [
        (state(.idle, current: nil), ["select": T, "next": T, "play": T, "pause": I, "toggle": T, "stop": I, "retry": I,
                                       "picked": I, "pickedNil": I, "resolved": I, "resolveFailed": I, "started": I, "eof": I,
                                       "playbackFailed": I, "lost": I, "restored": I,
                                       "playStream": T, "deferred": I, "reload": I]),
        (state(.tuning, current: nil, awaitingPick: true),
                                      ["select": T, "next": T, "play": T, "pause": T, "toggle": T, "stop": I, "retry": T,
                                       "picked": T, "pickedNil": F, "resolved": T, "resolveFailed": T, "started": T, "eof": T,
                                       "playbackFailed": T, "lost": O, "restored": T,
                                       "playStream": T, "deferred": T, "reload": T]),
        (state(.tuning),              ["select": T, "next": T, "play": T, "pause": T, "toggle": T, "stop": I, "retry": T,
                                       "picked": T, "pickedNil": T, "resolved": B, "resolveFailed": T, "started": T, "eof": T,
                                       "playbackFailed": T, "lost": O, "restored": T,
                                       "playStream": T, "deferred": T, "reload": T]),
        (state(.buffering),           ["select": T, "next": T, "play": B, "pause": B, "toggle": B, "stop": I, "retry": B,
                                       "picked": B, "pickedNil": B, "resolved": B, "resolveFailed": B, "started": P, "eof": T,
                                       "playbackFailed": T, "lost": O, "restored": B,
                                       "playStream": T, "deferred": B, "reload": B]),
        (state(.playing),             ["select": T, "next": T, "play": P, "pause": Z, "toggle": Z, "stop": I, "retry": P,
                                       "picked": P, "pickedNil": P, "resolved": P, "resolveFailed": P, "started": P, "eof": T,
                                       "playbackFailed": T, "lost": O, "restored": P,
                                       "playStream": T, "deferred": P, "reload": T]),
        (state(.paused),              ["select": T, "next": T, "play": P, "pause": Z, "toggle": P, "stop": I, "retry": Z,
                                       "picked": Z, "pickedNil": Z, "resolved": Z, "resolveFailed": Z, "started": Z, "eof": T,
                                       "playbackFailed": T, "lost": O, "restored": Z,
                                       "playStream": T, "deferred": Z, "reload": T]),
        (state(.offline),             ["select": O, "next": O, "play": O, "pause": O, "toggle": O, "stop": I, "retry": O,
                                       "picked": O, "pickedNil": O, "resolved": O, "resolveFailed": O, "started": O, "eof": O,
                                       "playbackFailed": O, "lost": O, "restored": T,
                                       "playStream": O, "deferred": O, "reload": O]),
        (state(.failed, current: nil), ["select": T, "next": T, "play": T, "pause": F, "toggle": T, "stop": I, "retry": T,
                                        "picked": F, "pickedNil": F, "resolved": F, "resolveFailed": F, "started": F, "eof": F,
                                        "playbackFailed": F, "lost": F, "restored": F,
                                        "playStream": T, "deferred": F, "reload": F]),
    ]
    for (start, row) in matrix {
        #expect(Set(row.keys) == Set(events.map(\.0)))
        for (name, event) in events {
            let (s, _) = SessionMachine.reduce(start, event)
            #expect(s.phase == row[name], "\(start.phase)\(start.awaitingPick ? "(awaiting pick)" : "") + \(name) → \(s.phase)")
        }
    }
}


@Test func playStreamPlaysAGivenStream() {
    var (s, fx) = run([.playStream(sc)], from: state(.playing))
    #expect(s.phase == .tuning && s.current == sc && !s.awaitingPick && s.failuresInARow == 0)
    #expect(fx[0] == [.resolve(sc), .flash(.tuning), .persist])
    (s, fx) = run([.resolved(sc.id), .started(sc.id)], from: s)
    #expect(s.phase == .playing && fx[1].contains(.prefetch(deep)))
    (s, fx) = run([.playStream(radio)], from: state(.idle, current: nil))
    #expect(s.phase == .buffering && fx[0] == [.load(radio), .persist])
    (s, fx) = run([.playStream(radio), .started(radio.id)])
    #expect(s.phase == .playing && s.genre == deep, "the stream's genre when none was picked")
    #expect(fx[1].contains(.prefetch(deep)))
    #expect(run([.playStream(sc)], from: state(.offline)).1[0].isEmpty)
}

@Test func withoutAGenreThereIsNothingToAdvanceTo() {
    var s = state(.playing)
    s.genre = nil
    let (eof, fx) = run([.endOfFile(yt.id)], from: s)
    #expect(eof.phase == .idle && eof.current == nil && fx[0] == [.stop, .nowPlaying(.idle, nil)])
    var tuning = state(.tuning)
    tuning.genre = nil
    let (failed, fx2) = run([.resolveFailed(yt.id, .transient)], from: tuning)
    #expect(failed.phase == .idle && fx2[0] == [.recordOutcome(yt.id, .failure(.transient)), .flash(.skipping), .stop,
                                                .nowPlaying(.idle, nil)])
}

@Test func deferralPicksNextWithoutCountingAFailure() {
    var start = state(.tuning)
    start.failuresInARow = 3
    let (s, fx) = run([.resolveDeferred(yt.id)], from: start)
    #expect(fx[0] == [.pick(deep, fastStart: false)])
    #expect(s.phase == .tuning && s.awaitingPick && s.current == nil && s.failuresInARow == 3)
    #expect(run([.resolveDeferred(sc.id)], from: state(.tuning)).1[0].isEmpty, "stale")
    #expect(run([.resolveDeferred(yt.id)], from: state(.playing)).1[0].isEmpty)
}

@Test func reloadCurrentRejoinsTheLiveEdge() {
    var (s, fx) = run([.reloadCurrent], from: state(.paused, current: radio))
    #expect(s.phase == .buffering && s.current == radio && fx[0] == [.load(radio)])
    (s, fx) = run([.started(radio.id)], from: s)
    #expect(s.phase == .playing && fx[0].first == .recordOutcome(radio.id, .success))
    let live = stream(.youtubeLive, 1)
    (s, fx) = run([.reloadCurrent], from: state(.paused, current: live))
    #expect(s.phase == .tuning && fx[0] == [.resolve(live), .flash(.tuning)])
    (s, fx) = run([.resolved(live.id)], from: s)
    #expect(s.phase == .buffering && fx[0] == [.load(live)])
    #expect(run([.reloadCurrent], from: state(.idle, current: nil)).1[0].isEmpty)
}
