// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// Why a source breaker is open (DESIGN §6.4's source-level classes).
public enum BreakerKind: String, Codable, Sendable, CaseIterable {
    /// Bot check, LOGIN_REQUIRED, 429: 6 h → 12 h → 24 h.
    case botCheck
    /// Two engine-class failures in a row: 15 min → 30 min → 1 h.
    case engine
    /// Three transient failures across at least two streams within 10 min: 15 min doubling to 2 h.
    case transient
}

/// The breaker schedules of DESIGN §6.4.
public enum BreakerPolicy {
    public struct Schedule: Sendable, Equatable {
        public var base: TimeInterval
        public var cap: TimeInterval

        /// The open time after `trips` earlier trips without a success in between: base, doubling, capped.
        public func duration(afterTrips trips: Int) -> TimeInterval {
            min(cap, base * pow(2, Double(min(max(trips, 0), 16))))
        }
    }

    public static func schedule(_ kind: BreakerKind) -> Schedule {
        switch kind {
        case .botCheck: Schedule(base: 6 * 3600, cap: 24 * 3600)
        case .engine: Schedule(base: 15 * 60, cap: 3600)
        case .transient: Schedule(base: 15 * 60, cap: 2 * 3600)
        }
    }

    /// Engine-class failures in a row (per platform) that trip the engine breaker and ask for an update check.
    public static let engineFailuresToTrip = 2
    /// Transient failures within `transientWindow`, across at least `transientDistinctStreams` streams.
    public static let transientFailuresToTrip = 3
    public static let transientDistinctStreams = 2
    public static let transientWindow: TimeInterval = 10 * 60
}

/// One platform's breaker (YouTube covers `youtube` and `youtube-live`). Closed, open until `reopenAt`, or
/// half-open once `reopenAt` has passed without a success: one probe pick may then try the source; a success closes
/// it and resets the escalation, a source-level failure re-opens it one step longer.
public struct SourceBreaker: Codable, Sendable, Equatable {
    public struct Mark: Codable, Sendable, Equatable {
        public var at: Date
        public var stream: StreamID
    }

    /// Trips per kind since the last success (the escalation step).
    public var trips: [BreakerKind: Int] = [:]
    /// The kind of the most recent trip.
    public var kind: BreakerKind?
    public var openedAt: Date?
    /// Open until this time; half-open after it (while `trips` is non-empty).
    public var reopenAt: Date?
    /// Engine-class failures since the last success or engine trip.
    public var engineFailuresInARow = 0
    /// Recent transient failures (pruned to the 10 min window).
    public var transient: [Mark] = []
    /// The half-open probe in flight. Not persisted: after a relaunch the next pick may probe again.
    public var probe: StreamID?

    private enum CodingKeys: String, CodingKey {
        case trips, kind, openedAt, reopenAt, engineFailuresInARow, transient
    }

    public init() {}

    // `[BreakerKind: Int]` would encode as a flat key/value array; JSON readers (`jq`) want an object.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: Int].self, forKey: .trips) ?? [:]
        trips = Dictionary(raw.compactMap { k, v in BreakerKind(rawValue: k).map { ($0, v) } }) { a, _ in a }
        kind = try c.decodeIfPresent(BreakerKind.self, forKey: .kind)
        openedAt = try c.decodeIfPresent(Date.self, forKey: .openedAt)
        reopenAt = try c.decodeIfPresent(Date.self, forKey: .reopenAt)
        engineFailuresInARow = try c.decodeIfPresent(Int.self, forKey: .engineFailuresInARow) ?? 0
        transient = try c.decodeIfPresent([Mark].self, forKey: .transient) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: trips.map { ($0.key.rawValue, $0.value) }), forKey: .trips)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(openedAt, forKey: .openedAt)
        try c.encodeIfPresent(reopenAt, forKey: .reopenAt)
        try c.encode(engineFailuresInARow, forKey: .engineFailuresInARow)
        try c.encode(transient, forKey: .transient)
    }

    public enum State: String, Codable, Sendable { case closed, open, halfOpen }

    public func state(now: Date) -> State {
        if let reopenAt, now < reopenAt { return .open }
        return trips.isEmpty ? .closed : .halfOpen
    }

    public var isPristine: Bool { trips.isEmpty && engineFailuresInARow == 0 && transient.isEmpty && reopenAt == nil }
}

/// What one recorded outcome did to a breaker.
public struct BreakerEvent: Sendable, Equatable {
    public enum Change: String, Sendable, Equatable {
        /// It opened (or re-opened after a failed probe).
        case tripped
        /// A success closed it.
        case reset
        /// Counted, still closed.
        case counted
        /// A failure that says nothing about the source (or arrived while it was open).
        case ignored
    }

    public var platform: SourceKind
    public var change: Change
    public var kind: BreakerKind?
    public var reopenAt: Date?
    /// The open time of this trip.
    public var duration: TimeInterval?
    /// This outcome completed a run of engine-class failures (DESIGN §6.4: "after 2 in a row, an update check").
    public var engineFailuresTripped = false
}

/// Every platform's breaker (DESIGN §6.4), persisted in `session.json` so a relaunch neither forgets an open
/// breaker nor its escalation. Pure: time arrives as arguments.
public struct SourceBreakers: Codable, Sendable, Equatable {
    public var platforms: [SourceKind: SourceBreaker] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: SourceBreaker].self)
        platforms = Dictionary(raw.compactMap { k, v in SourceKind(rawValue: k).map { ($0.platform, v) } }) { a, _ in a }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: platforms.map { ($0.key.rawValue, $0.value) }))
    }

    public subscript(_ source: SourceKind) -> SourceBreaker {
        get { platforms[source.platform] ?? SourceBreaker() }
        set { platforms[source.platform] = newValue.isPristine && newValue.probe == nil ? nil : newValue }
    }

    public func state(_ source: SourceKind, now: Date) -> SourceBreaker.State { self[source].state(now: now) }

    /// Platforms a pick must avoid. A half-open platform allows one probe: it is listed only while that probe is in
    /// flight, or always for background purposes (prefetch, hover), so the probe is a pick the user hears.
    public func blocked(now: Date, background: Bool = false) -> Set<SourceKind> {
        var out = Set<SourceKind>()
        for (platform, b) in platforms {
            switch b.state(now: now) {
            case .open: out.insert(platform)
            case .halfOpen: if background || b.probe != nil { out.insert(platform) }
            case .closed: break
            }
        }
        if out.contains(.youtube) { out.insert(.youtubeLive) }
        return out
    }

    /// `reopenAt` of each open platform.
    public func openUntil(now: Date) -> [SourceKind: Date] {
        var out: [SourceKind: Date] = [:]
        for (p, b) in platforms where b.state(now: now) == .open { out[p] = b.reopenAt }
        return out
    }

    /// A pick from `source` went ahead while its breaker is half-open: it is the probe.
    public mutating func notePicked(_ source: SourceKind, stream: StreamID, now: Date) {
        var b = self[source]
        guard b.state(now: now) == .halfOpen, b.probe == nil else { return }
        b.probe = stream
        self[source] = b
    }

    /// A probe that ended without telling anything (skipped, stopped, replaced) frees the half-open slot.
    public mutating func releaseProbe(_ stream: StreamID) {
        for (p, var b) in platforms where b.probe == stream {
            b.probe = nil
            platforms[p] = b
        }
    }

    /// A successful start: the platform's breaker closes and its escalation resets (DESIGN §6.4).
    @discardableResult
    public mutating func recordSuccess(_ source: SourceKind, stream: StreamID, now: Date) -> BreakerEvent {
        let had = !self[source].isPristine || self[source].probe != nil
        self[source] = SourceBreaker()
        return BreakerEvent(platform: source.platform, change: had ? .reset : .ignored)
    }

    /// A failed stream of `source`. Unavailable failures concern the stream, not the source. Radio has no source
    /// breaker: every station is its own host, so failures of different stations say nothing about the next one
    /// (their own backoff handles them), and radio is the source that must keep playing when the others stop.
    @discardableResult
    public mutating func recordFailure(_ source: SourceKind, stream: StreamID, failure: FailureClass, now: Date)
        -> BreakerEvent {
        let platform = source.platform
        guard platform != .radio else { return BreakerEvent(platform: platform, change: .ignored) }
        var b = self[source]
        let wasProbe = b.probe == stream
        if wasProbe { b.probe = nil }
        var event = BreakerEvent(platform: platform, change: .ignored)
        defer { self[source] = b }

        let state = b.state(now: now)
        let kind: BreakerKind?
        switch failure {
        case .unavailable:
            kind = nil
        case .botCheck:
            kind = .botCheck
        case .engine:
            b.engineFailuresInARow += 1
            if b.engineFailuresInARow >= BreakerPolicy.engineFailuresToTrip {
                event.engineFailuresTripped = true
                b.engineFailuresInARow = 0
                kind = .engine
            } else {
                kind = state == .halfOpen && wasProbe ? .engine : nil
            }
        case .transient:
            b.transient.append(SourceBreaker.Mark(at: now, stream: stream))
            b.transient.removeAll { now.timeIntervalSince($0.at) > BreakerPolicy.transientWindow }
            let distinct = Set(b.transient.map(\.stream)).count
            if b.transient.count >= BreakerPolicy.transientFailuresToTrip, distinct >= BreakerPolicy.transientDistinctStreams {
                kind = .transient
            } else {
                kind = state == .halfOpen && wasProbe ? .transient : nil
            }
        }
        guard let kind else {
            event.change = failure == .unavailable ? .ignored : .counted
            return event
        }
        // Already open (a second failure in flight when it tripped, or a stream the user chose by hand): the
        // escalation only steps on a trip from closed or a failed half-open probe, so racing requests can't
        // jump 6 h straight to 12 h.
        if state == .open {
            event.change = .ignored
            return event
        }
        let step = b.trips[kind] ?? 0
        let duration = BreakerPolicy.schedule(kind).duration(afterTrips: step)
        b.trips[kind] = step + 1
        b.kind = kind
        b.openedAt = now
        let until = now.addingTimeInterval(duration)
        b.reopenAt = max(b.reopenAt.map { $0 > now ? $0 : until } ?? until, until)
        if kind == .transient { b.transient = [] }
        event.change = .tripped
        event.kind = kind
        event.reopenAt = b.reopenAt
        event.duration = duration
        return event
    }

    /// Debug and report form: one entry per platform with a non-pristine breaker.
    public func summary(now: Date) -> [String: BreakerSummary] {
        var out: [String: BreakerSummary] = [:]
        for (p, b) in platforms {
            out[p.rawValue] = BreakerSummary(state: b.state(now: now), kind: b.kind, reopenAt: b.reopenAt,
                                             openedAt: b.openedAt, reopenAtUnix: b.reopenAt?.timeIntervalSince1970,
                                             reopenInSec: b.reopenAt.map { ($0.timeIntervalSince(now) * 10).rounded() / 10 },
                                             trips: Dictionary(uniqueKeysWithValues: b.trips.map { ($0.key.rawValue, $0.value) }),
                                             engineFailuresInARow: b.engineFailuresInARow,
                                             recentTransient: b.transient.count, probe: b.probe)
        }
        return out
    }
}

/// `state.json` / report view of one breaker.
public struct BreakerSummary: Codable, Sendable, Equatable {
    public var state: SourceBreaker.State
    public var kind: BreakerKind?
    public var reopenAt: Date?
    public var openedAt: Date?
    /// `reopenAt` as Unix seconds, whatever the encoder's date strategy (for `jq`).
    public var reopenAtUnix: Double?
    /// Seconds from the summary's `now` to `reopenAt` (negative once it has passed).
    public var reopenInSec: Double?
    public var trips: [String: Int]
    public var engineFailuresInARow: Int
    public var recentTransient: Int
    public var probe: StreamID?
}
