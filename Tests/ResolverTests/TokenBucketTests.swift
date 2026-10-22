// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import Testing
@testable import Resolver

/// PLAN M1: "the token bucket under a fake Clock: ≤ 123 YouTube resolves in the first simulated hour from a full
/// bucket and ≤ 120 in each later hour; hover is refused below 2 tokens".
@Suite struct TokenBucketTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func burstThenOnePerThirtySeconds() {
        var b = TokenBucket(now: t0)
        #expect(b.available(now: t0) == 3)
        for _ in 0..<3 { do { let ok = b.spend(for: .userPick, now: t0); #expect(ok) } }
        do { let ok = b.spend(for: .userPick, now: t0); #expect(!ok) }
        #expect(b.nextRefill(now: t0) == t0.addingTimeInterval(30))
        #expect(b.available(now: t0.addingTimeInterval(29.9)) == 0)
        #expect(b.available(now: t0.addingTimeInterval(30)) == 1)
        #expect(b.available(now: t0.addingTimeInterval(61)) == 2)
        #expect(b.available(now: t0.addingTimeInterval(3600)) == 3, "never above the burst")
        #expect(b.nextRefill(now: t0.addingTimeInterval(3600)) == nil)
    }

    @Test func aFullBucketsClockStartsAtTheSpend() {
        var b = TokenBucket(now: t0)
        let later = t0.addingTimeInterval(1000)
        do { let ok = b.spend(for: .prefetch, now: later); #expect(ok) }
        #expect(b.available(now: later.addingTimeInterval(29)) == 2)
        #expect(b.available(now: later.addingTimeInterval(30)) == 3)
    }

    @Test func hoverNeedsTwoTokens() {
        var b = TokenBucket(now: t0)
        do { let ok = b.spend(for: .hover, now: t0); #expect(ok) }      // 3 → 2
        do { let ok = b.spend(for: .hover, now: t0); #expect(ok) }      // 2 → 1
        #expect(!b.canSpend(for: .hover, now: t0))
        do { let ok = b.spend(for: .hover, now: t0); #expect(!ok, "refused below 2") }
        #expect(b.available(now: t0) == 1)
        for purpose in [ResolvePurpose.userPick, .prefetch, .canary, .retry] {
            #expect(TokenBucket.minimum(for: purpose) == 1)
        }
        do { let ok = b.spend(for: .userPick, now: t0); #expect(ok, "a user pick may take the last token") }
    }

    @Test func continuousDemandStaysWithinTheHourlyLimits() {
        var b = TokenBucket(now: t0)
        var perHour = [Int](repeating: 0, count: 6)
        for second in 0..<(6 * 3600) {
            let now = t0.addingTimeInterval(Double(second))
            if b.spend(for: .userPick, now: now) { perHour[second / 3600] += 1 }
        }
        #expect(perHour[0] <= 123, "\(perHour)")
        #expect(perHour[0] >= 120, "the bucket isn't stingier than designed: \(perHour)")
        for h in 1..<6 { #expect(perHour[h] <= 120, "hour \(h): \(perHour)") }
        #expect(perHour[1...].allSatisfy { $0 == 120 }, "sustained rate is exactly 120/h: \(perHour)")
    }

    @Test func noSlidingHourExceeds123() {
        var rng = SeededRandom(seed: 7)
        var b = TokenBucket(now: t0)
        var spends: [TimeInterval] = []
        var t: TimeInterval = 0
        while t < 5 * 3600 {
            t += Double(rng.next() % 40) + rng.unitInterval()  // bursts and lulls
            for _ in 0..<Int(rng.next() % 4) where b.spend(for: .userPick, now: t0.addingTimeInterval(t)) { spends.append(t) }
        }
        var start = 0
        for end in spends.indices {
            while spends[end] - spends[start] >= 3600 { start += 1 }
            #expect(end - start + 1 <= 123)
        }
        #expect(spends.count > 200)
    }

    @Test func purposesMapToPriorities() {
        #expect(ResolvePurpose.userPick.priority == .user)
        #expect(ResolvePurpose.retry.priority == .user)
        #expect(ResolvePurpose.prefetch.priority == .background)
        #expect(ResolvePurpose.hover.priority == .background)
        #expect(ResolvePurpose.canary.priority == .background)
    }
}
