// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// DESIGN §6.4's failure classes, as the Resolver's classifier reports them.
public enum FailureClass: String, Codable, Sendable, CaseIterable {
    /// Private, removed, geo-blocked, preview-only, DRM, Mixcloud `restrictedReason`: the stream itself is gone.
    case unavailable
    /// Timeout, 5xx, DNS: worth trying again later.
    case transient
    /// 403 on a fresh URL, format unavailable, n-challenge: yt-dlp needs a new tier or an update (source-level).
    case engine
    /// "Sign in to confirm you're not a bot", LOGIN_REQUIRED, 429 (source-level).
    case botCheck
}

/// One stream's failure history: when it may be picked again (DESIGN §6.4, M1 subset).
public struct StreamHealth: Codable, Sendable, Equatable {
    public var unavailableCount = 0
    public var firstUnavailableAt: Date?
    public var transientCount = 0
    /// Not eligible before this time.
    public var nextEligibleAt: Date?
    /// Hidden until a feed revision newer than this one arrives.
    public var hiddenAtRevision: Int?

    public init() {}

    public var isHealthy: Bool { self == StreamHealth() }

    /// Whether the stream may be picked at `now` under feed `revision`.
    public func isEligible(now: Date, revision: Int) -> Bool {
        if let hidden = hiddenAtRevision, revision <= hidden { return false }
        if let next = nextEligibleAt, now < next { return false }
        return true
    }
}

/// Backoff schedule for stream-level failures. Source-level classes (engine, bot-check) feed the M6 breakers and
/// the JS ladder instead, so they leave a stream's health untouched.
public enum HealthPolicy {
    /// Unavailable: skip 24 h, then 7 d.
    public static let unavailableFirstSkip: TimeInterval = 24 * 3600
    public static let unavailableRepeatSkip: TimeInterval = 7 * 24 * 3600
    /// Three unavailable failures spanning at least 7 days hide the stream until the next feed revision.
    public static let hideAfterUnavailable = 3
    public static let hideSpan: TimeInterval = 7 * 24 * 3600
    /// Transient: back off 1 h, doubling per consecutive failure, capped at 24 h.
    public static let transientBase: TimeInterval = 3600
    public static let transientCap: TimeInterval = 24 * 3600

    public static func recordFailure(_ h: inout StreamHealth, _ failure: FailureClass, now: Date, revision: Int) {
        switch failure {
        case .unavailable:
            h.unavailableCount += 1
            if h.firstUnavailableAt == nil { h.firstUnavailableAt = now }
            let skip = h.unavailableCount == 1 ? unavailableFirstSkip : unavailableRepeatSkip
            h.nextEligibleAt = max(h.nextEligibleAt ?? now, now.addingTimeInterval(skip))
            if h.unavailableCount >= hideAfterUnavailable, let first = h.firstUnavailableAt,
               now.timeIntervalSince(first) >= hideSpan {
                h.hiddenAtRevision = revision
            }
        case .transient:
            h.transientCount += 1
            let delay = min(transientCap, transientBase * pow(2, Double(min(h.transientCount - 1, 16))))
            h.nextEligibleAt = max(h.nextEligibleAt ?? now, now.addingTimeInterval(delay))
        case .engine, .botCheck:
            break
        }
    }

    /// A successful start resets the stream's health (DESIGN §6.4).
    public static func recordSuccess(_ h: inout StreamHealth) {
        h = StreamHealth()
    }
}
