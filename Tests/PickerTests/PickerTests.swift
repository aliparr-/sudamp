// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Testing
@testable import Picker

@Test func eligibilityFollowsDesignPredicate() {
    let yt = stream(.youtube, 1), live = stream(.youtubeLive, 1), sc = stream(.soundcloud, 1), radio = stream(.radio, 1)
    let base = PickContext(now: t0)
    for s in [yt, live, sc, radio] { #expect(Eligibility.reason(s, health: nil, context: base) == nil) }

    var c = base
    c.banned = [sc.id]
    #expect(Eligibility.reason(sc, health: nil, context: c) == .banned)

    var h = StreamHealth()
    h.nextEligibleAt = t0.addingTimeInterval(60)
    #expect(Eligibility.reason(sc, health: h, context: base) == .backingOff)
    #expect(Eligibility.reason(sc, health: h, context: PickContext(now: t0.addingTimeInterval(60))) == nil)

    c = base
    c.engine.sources[.youtube] = false        // the YouTube kill switch covers /live too
    #expect(Eligibility.reason(yt, health: nil, context: c) == .sourceDisabled)
    #expect(Eligibility.reason(live, health: nil, context: c) == .sourceDisabled)
    #expect(Eligibility.reason(sc, health: nil, context: c) == nil)

    c = base
    c.openBreakers = [.youtube]
    #expect(Eligibility.reason(live, health: nil, context: c) == .breakerOpen)
    #expect(Eligibility.reason(radio, health: nil, context: c) == nil)

    c = base
    c.engineReady = false                     // first launch: only radio until yt-dlp is installed
    #expect(Eligibility.reason(sc, health: nil, context: c) == .engineNotReady)
    #expect(Eligibility.reason(radio, health: nil, context: c) == nil)

    c = base
    c.youtubeTokens = 0
    #expect(Eligibility.reason(yt, health: nil, context: c) == .noYouTubeTokens)
    #expect(Eligibility.reason(live, health: nil, context: c) == .noYouTubeTokens)
    #expect(Eligibility.reason(sc, health: nil, context: c) == nil)
    c.cachedResolutions = [yt.id]             // a cached resolution needs no token
    #expect(Eligibility.reason(yt, health: nil, context: c) == nil)
    #expect(Eligibility.isReady(yt, context: c) && Eligibility.isReady(radio, context: c) && !Eligibility.isReady(sc, context: c))
}

@Test func youTubeWithoutTokensIsDeferredNotConsumed() {
    let yts = (0..<3).map { stream(.youtube, $0) }, sc = stream(.soundcloud, 0)
    var rng = SeededRandom(seed: 21)
    var picker = Picker(catalog: catalog(yts + [sc]), revision: 1, using: &rng)
    var c = PickContext(now: t0, youtubeTokens: 0)
    #expect(picker.next(genre: deep, context: c, using: &rng) == sc)
    // Only YouTube is left and it has no tokens: the bag is rebuilt once, and the one eligible item plays again
    // rather than silence.
    #expect(picker.next(genre: deep, context: c, using: &rng) == sc)
    // The YouTube items were never consumed: with tokens they come from the same bag.
    c.youtubeTokens = 3
    var got: [StreamRef] = []
    for _ in 0..<3 { got.append(picker.next(genre: deep, context: c, using: &rng)!) }
    #expect(Set(got) == Set(yts))
    c.engineReady = false
    #expect(picker.next(genre: deep, context: c, using: &rng) == nil, "nothing eligible even after the rebuild")
}

@Test func fastStartPrefersReadyThenRank() {
    var rng = SeededRandom(seed: 4)
    let yt = stream(.youtube, 1), mc = stream(.mixcloud, 1), sc = stream(.soundcloud, 1), radio = stream(.radio, 1)
    // Many seeds: whatever the shuffle, the fast-start pick is the best of the next 3 eligible in bag order.
    for seed in UInt64(0)..<200 {
        var r = SeededRandom(seed: seed)
        let start = Picker(catalog: catalog([yt, mc, sc, radio]), revision: 1, using: &r)
        // Two copies of one generator state build identical bags: the probe reveals the order the real pick sees.
        var probe = start, picker = start, rProbe = r
        var order: [StreamRef] = []
        for _ in 0..<4 { order.append(probe.next(genre: deep, context: PickContext(now: t0), using: &rProbe)!) }
        let window = Array(order.prefix(3))
        let first = picker.next(genre: deep, context: PickContext(now: t0), fastStart: true, using: &r)!
        let expected = window.contains(radio) ? radio
            : window.min { EngineConfig.defaults.fastStartPosition(of: $0.source) < EngineConfig.defaults.fastStartPosition(of: $1.source) }!
        #expect(first == expected, "seed \(seed): window \(window.map(\.id))")
        // The others in the window were deferred, not consumed.
        let rest = (0..<3).compactMap { _ in picker.next(genre: deep, context: PickContext(now: t0), using: &r) }
        #expect(Set(rest + [first]) == Set([yt, mc, sc, radio]))
    }
    // A cached YouTube resolution counts as ready and beats a better-ranked unready source.
    var picker = Picker(catalog: catalog([yt, sc]), revision: 1, using: &rng)
    let c = PickContext(now: t0, cachedResolutions: [yt.id])
    #expect(picker.next(genre: deep, context: c, fastStart: true, using: &rng) == yt)
}

@Test func healthBackoffSchedule() {
    let clock = FakeTimeSource(t0)
    var h = StreamHealth()
    HealthPolicy.recordFailure(&h, .unavailable, now: clock.now, revision: 1)
    #expect(h.nextEligibleAt == t0.addingTimeInterval(24 * 3600))
    clock.advance(by: 24 * 3600)
    #expect(h.isEligible(now: clock.now, revision: 1))
    HealthPolicy.recordFailure(&h, .unavailable, now: clock.now, revision: 1)
    #expect(h.nextEligibleAt == clock.now.addingTimeInterval(7 * 24 * 3600))
    #expect(h.hiddenAtRevision == nil)
    clock.advance(by: 7 * 24 * 3600)
    HealthPolicy.recordFailure(&h, .unavailable, now: clock.now, revision: 1)   // 3rd failure, 8 days after the 1st
    #expect(h.hiddenAtRevision == 1)
    clock.advance(by: 30 * 24 * 3600)
    #expect(!h.isEligible(now: clock.now, revision: 1), "hidden until the next feed revision")
    #expect(h.isEligible(now: clock.now, revision: 2))

    var t = StreamHealth()
    var delays: [TimeInterval] = []
    for _ in 0..<7 {
        HealthPolicy.recordFailure(&t, .transient, now: clock.now, revision: 1)
        delays.append(t.nextEligibleAt!.timeIntervalSince(clock.now))
        clock.advance(by: delays.last!)
    }
    #expect(delays == [1, 2, 4, 8, 16, 24, 24].map { $0 * 3600.0 })

    var s = StreamHealth()
    HealthPolicy.recordFailure(&s, .engine, now: clock.now, revision: 1)
    HealthPolicy.recordFailure(&s, .botCheck, now: clock.now, revision: 1)
    #expect(s.isHealthy, "source-level classes leave stream health alone")
    HealthPolicy.recordSuccess(&t)
    #expect(t.isHealthy)
}

@Test func pickerAppliesHealth() {
    var rng = SeededRandom(seed: 8)
    let a = stream(.soundcloud, 1), b = stream(.soundcloud, 2)
    var picker = Picker(catalog: catalog([a, b]), revision: 1, using: &rng)
    picker.recordFailure(a.id, .unavailable, now: t0)
    for _ in 0..<5 { #expect(picker.next(genre: deep, context: PickContext(now: t0), using: &rng) == b) }
    #expect(picker.next(genre: deep, context: PickContext(now: t0.addingTimeInterval(86_400)), using: &rng) != nil)
    picker.recordSuccess(a.id)
    #expect(picker.health(of: a.id) == nil)
}

@Test func genreAvailabilityAndSurprise() {
    var rng = SeededRandom(seed: 2)
    let streams = [stream(.youtube, 1), stream(.youtube, 2), stream(.radio, 1, genre: techno), stream(.soundcloud, 1, genre: techno)]
    let picker = Picker(catalog: catalog(streams), revision: 1, using: &rng)
    let c = PickContext(now: t0, engineReady: false)
    #expect(picker.eligibleCount(genre: deep, context: c) == 0)
    #expect(picker.unavailableReason(genre: deep, context: c) == .engineNotReady)
    #expect(picker.unavailableReason(genre: techno, context: c) == nil)
    for _ in 0..<50 { #expect(picker.surpriseGenre(context: c, using: &rng) == techno) }
    var counts: [GenreID: Int] = [:]
    for _ in 0..<4000 { counts[picker.surpriseGenre(context: PickContext(now: t0), using: &rng)!, default: 0] += 1 }
    #expect(chiSquare(observed: [counts[deep] ?? 0, counts[techno] ?? 0], expected: [0.5, 0.5]) < chiSquareCritical01[1]!)
}

@Test func persistenceMergeRoundTrip() throws {
    var rng = SeededRandom(seed: 13)
    let old = (0..<6).map { stream(.soundcloud, $0) } + [stream(.radio, 1, genre: techno)]
    var picker = Picker(catalog: catalog(old), revision: 1, using: &rng)
    var played: [StreamRef] = []
    for _ in 0..<3 { played.append(picker.next(genre: deep, context: PickContext(now: t0), using: &rng)!) }
    picker.recordFailure(old[5].id, .transient, now: t0)
    picker.recordFailure(old[4].id, .transient, now: t0)

    // Round trip through session.json on disk.
    let dir = FileManager.default.temporaryDirectory.appending(path: "picker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "session.json")
    let last = LastSession(genre: deep, stream: played.last!.id, positionSec: 42.5, wasPlaying: true, savedAt: t0)
    try StateFile.save(SessionFile(picker: picker.state, last: last), to: url)
    let loaded = try #require(StateFile.load(SessionFile.self, from: url))
    #expect(loaded.picker == picker.state)
    #expect(loaded.last == last)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("\"deep-house\"") && text.contains("\"\(old[5].id)\""), "bags and health are keyed objects")

    // A new feed revision removes one played and one unplayed stream, and adds two.
    let removedPlayed = played[0]
    let removedUnplayed = old.first { s in s.genres == [deep] && !played.contains(s) && s.id != old[4].id }!
    let added = [stream(.mixcloud, 1), stream(.mixcloud, 2)]
    let newStreams = old.filter { $0 != removedPlayed && $0 != removedUnplayed } + added
    var restored = Picker(catalog: catalog(newStreams), revision: 2, restoring: loaded.picker, using: &rng)
    let bag = try #require(restored.state.bags[deep])
    #expect(bag.cursor == 2)
    #expect(Array(bag.order.prefix(2)) == played.dropFirst().map(\.id))
    #expect(Set(added.map(\.id)).isSubset(of: Set(bag.upcoming)))
    #expect(!bag.order.contains(removedPlayed.id) && !bag.order.contains(removedUnplayed.id))
    #expect(restored.state.revision == 2)
    #expect(restored.health(of: old[4].id) != nil)
    if removedUnplayed.id == old[5].id { #expect(restored.health(of: old[5].id) == nil) }

    // The rest of the bag plays out without repeating what was already played.
    var rest: [StreamRef] = []
    let later = PickContext(now: t0.addingTimeInterval(7200))
    for _ in 0..<bag.upcoming.count { rest.append(restored.next(genre: deep, context: later, using: &rng)!) }
    #expect(Set(rest.map(\.id)) == Set(bag.upcoming))
    #expect(Set(rest).isDisjoint(with: played))
}

@Test func corruptOrFutureStateFilesLoadAsNil() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let bad = dir.appending(path: "a.json"), future = dir.appending(path: "b.json")
    try Data("{oops".utf8).write(to: bad)
    try Data(#"{"version": 2, "picker": {"bags": {}, "health": {}, "revision": 0}}"#.utf8).write(to: future)
    #expect(StateFile.load(SessionFile.self, from: bad) == nil)
    #expect(StateFile.load(SessionFile.self, from: future) == nil)
    #expect(StateFile.load(SessionFile.self, from: dir.appending(path: "missing.json")) == nil)
}

@Test func libraryBansFavouritesAndHistory() throws {
    var lib = Library()
    let a = stream(.soundcloud, 1).id, b = stream(.soundcloud, 2).id
    lib.ban(a); lib.ban(b); lib.ban(a)
    #expect(lib.banned == [b, a])
    #expect(lib.unban() == a && lib.bannedSet == [b])
    #expect(lib.unban(b) == b && lib.banned.isEmpty)
    lib.toggleFavourite(a); lib.toggleFavourite(b); lib.toggleFavourite(a)
    #expect(lib.favourites == [b])
    for i in 0..<250 { lib.recordPlay(a, genre: deep, at: t0.addingTimeInterval(Double(i))) }
    #expect(lib.history.count == Library.historyLimit)
    #expect(lib.history.first?.playedAt == t0.addingTimeInterval(50))
    let data = try JSONEncoder().encode(lib)
    #expect(try JSONDecoder().decode(Library.self, from: data) == lib)
}
