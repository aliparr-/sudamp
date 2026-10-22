// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// When a resolved URL may be loaded (DESIGN §6.3 `available_at`): never before `available_at`; a cold pick waits
/// up to 3 s, beyond that the resolution is kept for later and the next pick plays.
public enum Availability: Sendable, Equatable {
    case now
    /// Load after this many seconds (≤ `maxWait`).
    case wait(TimeInterval)
    /// Too far ahead for a pick that the user is waiting on: keep it, play something else.
    case deferred(TimeInterval)

    /// DESIGN §6.3: "if a cold pick must wait over 3 s, keep the resolution and play the next pick".
    public static let maxWait: TimeInterval = 3

    public static func of(_ stream: ResolvedStream, now: Date) -> Availability {
        let wait = stream.wait(now: now)
        if wait <= 0 { return .now }
        return wait <= maxWait ? .wait(wait) : .deferred(wait)
    }

    public var seconds: TimeInterval {
        switch self {
        case .now: 0
        case .wait(let s), .deferred(let s): s
        }
    }
}

/// Resolved streams keyed by stream ID (DESIGN §6.3 "Cache"): valid until `expire − 15 min` (YouTube ~6 h,
/// SoundCloud ~2.8 h, following each URL's own `expire`/`expires`), 1 h for URLs without an expiry (Mixcloud HLS
/// and progressive), and YouTube entries are dropped when the network path changes, because googlevideo URLs are
/// bound to the client's IP. Pure: time is passed in.
public struct ResolutionCache: Sendable {
    public static let expiryMargin: TimeInterval = 15 * 60
    public static let noExpiryLifetime: TimeInterval = 3600

    public struct Entry: Sendable, Equatable {
        public let stream: ResolvedStream
        public let validUntil: Date
    }

    public private(set) var entries: [StreamID: Entry] = [:]

    public init() {}

    /// The end of a resolution's useful life.
    public static func validUntil(_ stream: ResolvedStream) -> Date {
        if let expires = stream.expiresAt {
            return Date(timeIntervalSince1970: expires - expiryMargin)
        }
        return Date(timeIntervalSince1970: stream.resolvedAt + noExpiryLifetime)
    }

    /// Stores a resolution unless it is already past its useful life. Returns whether it was kept.
    @discardableResult
    public mutating func insert(_ stream: ResolvedStream, for id: StreamID, now: Date) -> Bool {
        let until = Self.validUntil(stream)
        guard until > now, stream.source != .radio else {
            entries[id] = nil
            return false
        }
        entries[id] = Entry(stream: stream, validUntil: until)
        return true
    }

    /// The cached resolution if still valid at `now`.
    public func lookup(_ id: StreamID, now: Date) -> ResolvedStream? {
        guard let e = entries[id], e.validUntil > now else { return nil }
        return e.stream
    }

    public mutating func remove(_ id: StreamID) { entries[id] = nil }

    public mutating func removeAll() { entries.removeAll() }

    /// Drops expired entries.
    public mutating func prune(now: Date) { entries = entries.filter { $0.value.validUntil > now } }

    /// IDs with a valid resolution.
    public func validIDs(now: Date) -> Set<StreamID> { Set(entries.filter { $0.value.validUntil > now }.keys) }

    /// IDs that are valid *and* loadable within `Availability.maxWait` (what fast-start may treat as ready).
    public func readyIDs(now: Date) -> Set<StreamID> {
        Set(entries.filter { $0.value.validUntil > now && $0.value.stream.wait(now: now) <= Availability.maxWait }.keys)
    }

    /// The network path changed: YouTube URLs are IP-bound, so they go; others stay. Returns what was dropped.
    @discardableResult
    public mutating func networkPathChanged() -> [StreamID] {
        let dropped = entries.filter { $0.value.stream.source.platform == .youtube }.map(\.key)
        for id in dropped { entries[id] = nil }
        return dropped.sorted()
    }

    public var count: Int { entries.count }
}
