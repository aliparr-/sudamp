// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The JS ladder's local adaptation (DESIGN §6.2): "Two tier-1 failures while tier 2 works start picks at tier 2 for
/// 24 h." A tier-1 engine-class failure followed by a tier-2 success counts; a tier-1 success resets the count.
/// After the second, YouTube picks start at tier 2 until `preferTier2Until`, then return to tier 1. Persisted (the
/// Resolver's state file) and driven by a `TimeSource`, so `SUDAMP_CLOCK_OFFSET` can cross the 24 h boundary.
public struct TierAdaptation: Sendable, Equatable, Codable {
    public static let failuresToAdapt = 2
    public static let preferenceWindow: TimeInterval = 24 * 3600

    /// Tier-1 failures rescued by tier 2 since the last tier-1 success.
    public private(set) var rescuedFailures: Int
    public private(set) var preferTier2Until: Date?

    public init(rescuedFailures: Int = 0, preferTier2Until: Date? = nil) {
        self.rescuedFailures = rescuedFailures
        self.preferTier2Until = preferTier2Until
    }

    /// The tier a YouTube resolve starts at.
    public func startTier(now: Date) -> ResolveTier {
        if let until = preferTier2Until, now < until { return .quickjs }
        return .jsless
    }

    public func prefersTier2(now: Date) -> Bool { startTier(now: now) == .quickjs }

    /// Tier 1 worked: the ladder isn't needed.
    public mutating func recordTier1Success() {
        rescuedFailures = 0
    }

    /// Tier 1 failed with an engine-class error and tier 2 was tried. Returns true when this starts the 24 h
    /// preference.
    @discardableResult
    public mutating func recordStepUp(tier2Succeeded: Bool, now: Date) -> Bool {
        guard tier2Succeeded else { return false }
        rescuedFailures += 1
        guard rescuedFailures >= Self.failuresToAdapt else { return false }
        rescuedFailures = 0
        preferTier2Until = now.addingTimeInterval(Self.preferenceWindow)
        return true
    }

    /// Drops an expired preference (so the persisted state reads cleanly).
    public mutating func expire(now: Date) {
        if let until = preferTier2Until, now >= until { preferTier2Until = nil }
    }
}
