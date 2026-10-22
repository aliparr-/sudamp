// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation

/// The Picker's persisted part of `session.json`: one bag per genre and each stream's health.
public struct PickerState: Codable, Sendable, Equatable {
    public var bags: [GenreID: ShuffleBag]
    public var health: [StreamID: StreamHealth]
    /// The feed revision these bags were last merged with.
    public var revision: Int

    public init(bags: [GenreID: ShuffleBag] = [:], health: [StreamID: StreamHealth] = [:], revision: Int = 0) {
        self.bags = bags
        self.health = health
        self.revision = revision
    }
}

/// Picks streams for genres from the active catalog (DESIGN §7.3). Pure: time, randomness and every external
/// input arrive as arguments, so a seeded generator and a fixed `PickContext` reproduce any sequence.
public struct Picker: Sendable {
    public private(set) var catalog: FeedCatalog
    public private(set) var state: PickerState

    /// How many eligible items fast-start considers.
    public static let fastStartWindow = 3

    /// Starts from a saved state (or none), merged with `catalog`.
    public init(catalog: FeedCatalog, revision: Int, restoring saved: PickerState? = nil,
                using rng: inout some RandomNumberGenerator) {
        self.catalog = catalog
        self.state = saved ?? PickerState(revision: revision)
        update(catalog: catalog, revision: revision, using: &rng)
    }

    /// Applies a new catalog: bags merge (new IDs after the cursor, removed IDs dropped), bags of removed genres and
    /// health of removed streams are dropped. Streams hidden at an older revision become eligible again on their own
    /// (`StreamHealth.isEligible` compares revisions).
    public mutating func update(catalog: FeedCatalog, revision: Int, using rng: inout some RandomNumberGenerator) {
        self.catalog = catalog
        var bags: [GenreID: ShuffleBag] = [:]
        for genre in catalog.genres {
            guard var bag = state.bags[genre.id] else { continue }
            bag.merge(members: catalog.streams(in: genre.id).map(\.id), using: &rng)
            bags[genre.id] = bag
        }
        state.bags = bags
        state.health = state.health.filter { catalog[$0.key] != nil && !$0.value.isHealthy }
        state.revision = revision
    }

    func members(of genre: GenreID) -> [BagMember] {
        catalog.streams(in: genre).map { BagMember(id: $0.id, weight: $0.weight) }
    }

    public func health(of id: StreamID) -> StreamHealth? { state.health[id] }

    /// The next stream for `genre`, or nil if none is eligible. With `fastStart` (the first pick after a genre change
    /// or launch) it looks at the next 3 eligible items and prefers a ready one (radio or cached), then the feed's
    /// `fastStartRank`, then bag order.
    public mutating func next(genre: GenreID, context: PickContext, fastStart: Bool = false,
                              using rng: inout some RandomNumberGenerator) -> StreamRef? {
        guard catalog.genre(genre) != nil else { return nil }
        var bag = state.bags[genre] ?? ShuffleBag()
        let catalog = self.catalog, health = state.health
        let eligible: (StreamID) -> Bool = { id in
            guard let s = catalog[id] else { return false }
            return Eligibility.isEligible(s, health: health[id], context: context)
        }
        let picked: StreamID?
        if fastStart {
            picked = bag.next(members: members(of: genre), candidates: Picker.fastStartWindow, using: &rng,
                              isEligible: eligible) { ids in
                let ranked = ids.enumerated().map { i, id -> (ready: Int, rank: Int, i: Int) in
                    let s = catalog[id]!
                    return (Eligibility.isReady(s, context: context) ? 0 : 1, context.engine.fastStartPosition(of: s.source), i)
                }
                return ranked.min { ($0.ready, $0.rank, $0.i) < ($1.ready, $1.rank, $1.i) }!.i
            }
        } else {
            picked = bag.next(members: members(of: genre), using: &rng, isEligible: eligible)
        }
        state.bags[genre] = bag
        return picked.flatMap { catalog[$0] }
    }

    /// Eligible streams in a genre right now (the menu disables a genre at 0; Surprise Me weights by it).
    public func eligibleCount(genre: GenreID, context: PickContext) -> Int {
        catalog.streams(in: genre).filter { Eligibility.isEligible($0, health: state.health[$0.id], context: context) }.count
    }

    /// Why a genre has nothing to play: the most common reason among its streams, or nil if something is eligible.
    public func unavailableReason(genre: GenreID, context: PickContext) -> Ineligibility? {
        var counts: [Ineligibility: Int] = [:]
        for s in catalog.streams(in: genre) {
            guard let r = Eligibility.reason(s, health: state.health[s.id], context: context) else { return nil }
            counts[r, default: 0] += 1
        }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key.rawValue > $1.key.rawValue }?.key
    }

    /// Surprise Me: a genre chosen with probability proportional to its eligible count (DESIGN §7.3).
    public func surpriseGenre(context: PickContext, using rng: inout some RandomNumberGenerator) -> GenreID? {
        let weighted = catalog.genres.map { ($0.id, eligibleCount(genre: $0.id, context: context)) }.filter { $0.1 > 0 }
        let total = weighted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        var r = Int.random(in: 0..<total, using: &rng)
        for (id, n) in weighted {
            if r < n { return id }
            r -= n
        }
        return weighted.last?.0
    }

    // MARK: Health

    public mutating func recordFailure(_ id: StreamID, _ failure: FailureClass, now: Date) {
        guard catalog[id] != nil else { return }
        var h = state.health[id] ?? StreamHealth()
        HealthPolicy.recordFailure(&h, failure, now: now, revision: state.revision)
        state.health[id] = h.isHealthy ? nil : h
    }

    /// Convenience over `recordFailure(_:_:now:)` for callers holding a clock (`SystemTimeSource`, `FakeTimeSource`).
    public mutating func recordFailure(_ id: StreamID, _ failure: FailureClass, clock: any TimeSource) {
        recordFailure(id, failure, now: clock.now)
    }

    public mutating func recordSuccess(_ id: StreamID) {
        state.health[id] = nil
    }
}
