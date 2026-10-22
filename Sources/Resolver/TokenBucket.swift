// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Why a YouTube resolve is wanted (DESIGN §6.3 "Rate": user picks, prefetch, hover, canary and retries share one
/// bucket).
public enum ResolvePurpose: String, Sendable, Codable, CaseIterable {
    case userPick
    case prefetch
    case hover
    case canary
    /// A second request for the same pick (the JS ladder's tier-2 step-up, a mid-stream re-resolve).
    case retry

    /// User-facing work pre-empts background resolves (DESIGN §6.3 "Concurrency").
    public var priority: ResolvePriority { self == .userPick || self == .retry ? .user : .background }
}

/// The shared YouTube token bucket (DESIGN §6.3): burst 3, one token back every 30 s, so at most 123 resolves in
/// any hour (3 + 120 refills) and 120 an hour sustained. Hover pre-resolves spend a token only while ≥ 2 remain.
/// Tokens are whole: refills accrue from `anchor` in exact 30 s steps, and the clock only runs while the bucket is
/// below its burst, so a full bucket's next token arrives 30 s after the spend that left it.
public struct TokenBucket: Sendable, Equatable, Codable {
    public static let burst = 3
    public static let refillInterval: TimeInterval = 30
    /// Hover is refused below this many tokens.
    public static let hoverMinimum = 2

    public private(set) var tokens: Int
    /// The time the next refill counts from (meaningful only while `tokens < burst`).
    public private(set) var anchor: Date

    public init(now: Date, tokens: Int = TokenBucket.burst) {
        self.tokens = min(max(tokens, 0), Self.burst)
        anchor = now
    }

    /// Whole tokens available at `now`.
    public func available(now: Date) -> Int {
        var copy = self
        copy.refill(now: now)
        return copy.tokens
    }

    /// The minimum a purpose needs before it may spend.
    public static func minimum(for purpose: ResolvePurpose) -> Int { purpose == .hover ? hoverMinimum : 1 }

    /// Whether `purpose` could spend at `now` (without spending).
    public func canSpend(for purpose: ResolvePurpose, now: Date) -> Bool {
        available(now: now) >= Self.minimum(for: purpose)
    }

    /// Takes one token if `purpose` may; false means "no YouTube request now" (defer the item, skip the hover).
    public mutating func spend(for purpose: ResolvePurpose, now: Date) -> Bool {
        refill(now: now)
        guard tokens >= Self.minimum(for: purpose) else { return false }
        if tokens == Self.burst { anchor = now }
        tokens -= 1
        return true
    }

    /// When the next token arrives (nil when full).
    public func nextRefill(now: Date) -> Date? {
        var copy = self
        copy.refill(now: now)
        return copy.tokens >= Self.burst ? nil : copy.anchor.addingTimeInterval(Self.refillInterval)
    }

    mutating func refill(now: Date) {
        guard tokens < Self.burst else { return }
        let elapsed = now.timeIntervalSince(anchor)
        guard elapsed >= Self.refillInterval else { return }
        let steps = Int((elapsed / Self.refillInterval).rounded(.down))
        tokens = min(Self.burst, tokens + steps)
        anchor = anchor.addingTimeInterval(Double(steps) * Self.refillInterval)
    }
}
