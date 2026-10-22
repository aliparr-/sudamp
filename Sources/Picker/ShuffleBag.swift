// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// A bag member and its pick weight.
public struct BagMember: Sendable, Hashable {
    public let id: StreamID
    public let weight: Double

    public init(id: StreamID, weight: Double) {
        self.id = id
        self.weight = weight
    }
}

/// One genre's weighted shuffle bag (DESIGN §7.3). Each build is a weighted random permutation (Efraimidis–Spirakis:
/// key = U(0,1)^(1/weight), sorted descending), so every member plays once per bag and heavier members tend to come
/// earlier. `order[..<cursor]` has been played; `order[cursor...]` is still to come.
public struct ShuffleBag: Codable, Sendable, Equatable {
    public private(set) var order: [StreamID] = []
    public private(set) var cursor = 0
    /// The most recent picks, newest last (for last-k avoidance across bag boundaries).
    public private(set) var recent: [StreamID] = []

    /// Last-k avoidance never looks further back than this.
    public static let recentLimit = 3

    public init() {}

    /// The items not yet played in this bag, in order.
    public var upcoming: ArraySlice<StreamID> { order[min(cursor, order.count)...] }

    // MARK: Build

    /// Rebuilds the bag from `members`: a fresh weighted permutation, then last-k avoidance, cursor at 0.
    public mutating func rebuild(_ members: [BagMember], using rng: inout some RandomNumberGenerator) {
        var unique: [BagMember] = []
        var seen = Set<StreamID>()
        for m in members where seen.insert(m.id).inserted { unique.append(m) }
        // log(u)/w orders exactly like u^(1/w) and avoids underflow for small weights; 1 - u keeps u in (0, 1].
        let keyed = unique.map { m -> (key: Double, id: StreamID) in
            let u = 1 - Double.random(in: 0..<1, using: &rng)
            return (log(u) / max(m.weight, .leastNormalMagnitude), m.id)
        }
        order = keyed.sorted { $0.key != $1.key ? $0.key > $1.key : $0.id < $1.id }.map(\.id)
        cursor = 0
        avoidRecent()
    }

    /// k = min(3, n/3): none of the last k picks may sit in the first k slots of a new bag. The first k non-recent
    /// items move to the front in their shuffled order; everything else keeps its relative order.
    mutating func avoidRecent() {
        let k = min(ShuffleBag.recentLimit, order.count / 3)
        guard k > 0 else { return }
        let avoid = Set(recent.suffix(k))
        var front: [StreamID] = []
        var rest: [StreamID] = []
        for id in order {
            if front.count < k && !avoid.contains(id) { front.append(id) } else { rest.append(id) }
        }
        order = front + rest
    }

    // MARK: Pick

    /// Walks from the cursor and takes the first eligible item. Ineligible items are deferred, not consumed: they
    /// stay ahead of the cursor for later calls. If nothing ahead is eligible, the bag is rebuilt once.
    public mutating func next(members: [BagMember], using rng: inout some RandomNumberGenerator,
                              isEligible: (StreamID) -> Bool) -> StreamID? {
        next(members: members, candidates: 1, using: &rng, isEligible: isEligible, choose: { _ in 0 })
    }

    /// Gathers up to `candidates` eligible items from the cursor and consumes the one `choose` returns (an index into
    /// the candidates, in bag order). Used by fast-start to prefer ready items among the next few.
    public mutating func next(members: [BagMember], candidates: Int, using rng: inout some RandomNumberGenerator,
                              isEligible: (StreamID) -> Bool, choose: ([StreamID]) -> Int) -> StreamID? {
        var found = gather(candidates, isEligible)
        if found.isEmpty {
            rebuild(members, using: &rng)
            found = gather(candidates, isEligible)
        }
        guard !found.isEmpty else { return nil }
        let pick = found[min(max(choose(found.map { order[$0] }), 0), found.count - 1)]
        return consume(at: pick)
    }

    private func gather(_ limit: Int, _ isEligible: (StreamID) -> Bool) -> [Int] {
        var out: [Int] = []
        var i = cursor
        while i < order.count && out.count < max(limit, 1) {
            if isEligible(order[i]) { out.append(i) }
            i += 1
        }
        return out
    }

    /// Moves `order[index]` to the cursor (deferred items keep their order behind it) and advances.
    private mutating func consume(at index: Int) -> StreamID {
        let id = order.remove(at: index)
        order.insert(id, at: cursor)
        cursor += 1
        recent.append(id)
        if recent.count > ShuffleBag.recentLimit { recent.removeFirst(recent.count - ShuffleBag.recentLimit) }
        return id
    }

    // MARK: Catalog changes

    /// Applies a membership change (a new feed, or a restored session.json): removed IDs are dropped, new IDs go at
    /// random positions after the cursor, so neither replays the played part nor front-loads the newcomers.
    /// Also repairs a corrupted saved bag (duplicates, cursor out of range).
    public mutating func merge(members: [StreamID], using rng: inout some RandomNumberGenerator) {
        let keep = Set(members)
        var seen = Set<StreamID>()
        var kept: [StreamID] = []
        var newCursor = 0
        let oldCursor = min(max(cursor, 0), order.count)
        for (i, id) in order.enumerated() where keep.contains(id) && seen.insert(id).inserted {
            kept.append(id)
            if i < oldCursor { newCursor += 1 }
        }
        for id in members where seen.insert(id).inserted {
            kept.insert(id, at: Int.random(in: newCursor...kept.count, using: &rng))
        }
        order = kept
        cursor = newCursor
        recent = recent.filter(keep.contains)
    }
}
