// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Testing
@testable import Picker

@Test func noRepeatWithinABag() {
    var rng = SeededRandom(seed: 1)
    let all = ids("a", 12)
    var bag = ShuffleBag()
    for round in 0..<20 {
        var seen: [StreamID] = []
        for _ in all { seen.append(bag.next(members: members(all), using: &rng) { _ in true }!) }
        #expect(Set(seen) == Set(all), "round \(round)")
        #expect(seen.count == all.count)
    }
}

@Test func weightedFirstPicksFitTheirWeights() {
    // Efraimidis–Spirakis: the first item of a fresh bag is item i with probability w_i / Σw.
    let all = ids("w", 5)
    let weights: [Double] = [1, 2, 3, 4, 5]
    let m = zip(all, weights).map { BagMember(id: $0, weight: $1) }
    var rng = SeededRandom(seed: 0x5EED)
    var counts = [Int](repeating: 0, count: all.count)
    for _ in 0..<10_000 {
        var bag = ShuffleBag()
        let first = bag.next(members: m, using: &rng) { _ in true }!
        counts[all.firstIndex(of: first)!] += 1
    }
    let total = weights.reduce(0, +)
    let x2 = chiSquare(observed: counts, expected: weights.map { $0 / total })
    #expect(x2 < chiSquareCritical01[4]!, "χ² = \(x2), counts \(counts)")
    // And the test has power: the same draws are far from uniform.
    #expect(chiSquare(observed: counts, expected: [Double](repeating: 0.2, count: 5)) > 100)
}

@Test func equalWeightsGiveUniformPositions() {
    let all = ids("u", 4)
    var rng = SeededRandom(seed: 99)
    var firstCounts = [Int](repeating: 0, count: 4), lastCounts = [Int](repeating: 0, count: 4)
    for _ in 0..<10_000 {
        var bag = ShuffleBag()
        bag.rebuild(members(all), using: &rng)
        firstCounts[all.firstIndex(of: bag.order.first!)!] += 1
        lastCounts[all.firstIndex(of: bag.order.last!)!] += 1
    }
    #expect(chiSquare(observed: firstCounts, expected: [0.25, 0.25, 0.25, 0.25]) < chiSquareCritical01[3]!)
    #expect(chiSquare(observed: lastCounts, expected: [0.25, 0.25, 0.25, 0.25]) < chiSquareCritical01[3]!)
}

@Test func deferralDoesNotConsume() {
    var rng = SeededRandom(seed: 7)
    let all = ids("d", 6)
    let blocked = all[2]
    var bag = ShuffleBag()
    var picked: [StreamID] = []
    for _ in 0..<5 { picked.append(bag.next(members: members(all), using: &rng) { $0 != blocked }!) }
    #expect(!picked.contains(blocked))
    #expect(Set(picked).count == 5)
    #expect(Array(bag.upcoming) == [blocked], "the deferred item is still in the bag")
    // Once eligible, it comes next, from the same bag (no rebuild in between).
    #expect(bag.next(members: members(all), using: &rng) { _ in true } == blocked)
    #expect(bag.cursor == 6)
}

@Test func exhaustionRebuildsOnceThenGivesUp() {
    var rng = SeededRandom(seed: 3)
    let all = ids("e", 4)
    var bag = ShuffleBag()
    for _ in 0..<4 { _ = bag.next(members: members(all), using: &rng) { _ in true } }
    #expect(bag.upcoming.isEmpty)
    // Exhausted: rebuilt once and walked again.
    #expect(bag.next(members: members(all), using: &rng) { _ in true } != nil)
    #expect(bag.cursor == 1)
    // Nothing eligible at all: nil, and the bag is a fresh full one again.
    #expect(bag.next(members: members(all), using: &rng) { _ in false } == nil)
    #expect(bag.cursor == 0 && Set(bag.order) == Set(all))
}

@Test func lastKAvoidanceAcrossBags() {
    // n = 9 → k = 3: none of the last 3 picks may open the next bag in its first 3 slots.
    let all = ids("k", 9)
    for seed in UInt64(0)..<300 {
        var rng = SeededRandom(seed: seed)
        var bag = ShuffleBag()
        var played: [StreamID] = []
        for _ in 0..<(9 * 4) { played.append(bag.next(members: members(all), using: &rng) { _ in true }!) }
        for b in 1..<4 {
            let lastOfPrevious = Set(played[(b * 9 - 3)..<(b * 9)])
            let firstOfNext = played[(b * 9)..<(b * 9 + 3)]
            #expect(lastOfPrevious.isDisjoint(with: firstOfNext), "seed \(seed) bag \(b)")
        }
    }
    // n = 4 → k = 1; n = 2 → k = 0 (no avoidance possible).
    var rng = SeededRandom(seed: 11)
    let four = ids("f", 4)
    var bag = ShuffleBag()
    var last: StreamID?
    for i in 0..<400 {
        let id = bag.next(members: members(four), using: &rng) { _ in true }!
        #expect(id != last, "draw \(i) repeated across the bag boundary")
        last = id
    }
}

@Test func mergeDropsRemovedAndInsertsNewAfterTheCursor() {
    var rng = SeededRandom(seed: 5)
    let all = ids("m", 8)
    var bag = ShuffleBag()
    var played: [StreamID] = []
    for _ in 0..<4 { played.append(bag.next(members: members(all), using: &rng) { _ in true }!) }
    let removedPlayed = played[1], removedUpcoming = bag.upcoming.first!
    let added = ids("n", 3)
    let newMembers = all.filter { $0 != removedPlayed && $0 != removedUpcoming } + added
    for seed in UInt64(0)..<50 {
        var b = bag
        var r = SeededRandom(seed: seed)
        b.merge(members: newMembers, using: &r)
        #expect(b.cursor == 3)
        #expect(Array(b.order[..<3]) == played.filter { $0 != removedPlayed })
        #expect(Set(b.order) == Set(newMembers) && b.order.count == newMembers.count)
        #expect(Set(added).isSubset(of: Set(b.upcoming)))
        #expect(!b.recent.contains(removedPlayed))
    }
}

@Test func mergeRepairsCorruptState() throws {
    let a = ids("c", 3)
    let json = #"{"order":["\#(a[0])","\#(a[0])","\#(a[1])"],"cursor":99,"recent":[]}"#
    var bag = try JSONDecoder().decode(ShuffleBag.self, from: Data(json.utf8))
    var rng = SeededRandom(seed: 1)
    bag.merge(members: a, using: &rng)
    #expect(bag.order.count == 3 && Set(bag.order) == Set(a))
    #expect(bag.cursor == 2)
}
