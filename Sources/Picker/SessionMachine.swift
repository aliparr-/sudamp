// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// Playback phases (DESIGN §4).
public enum PlaybackPhase: String, Codable, Sendable, CaseIterable {
    case idle
    /// Waiting for a pick or a resolve.
    case tuning
    /// Loaded into mpv, waiting for the first audio.
    case buffering
    case playing
    case paused
    case offline
    /// Stopped after too many failures in a row, or nothing in the genre is playable.
    case failed
}

/// Marquee messages (DESIGN §3).
public enum FlashMessage: Equatable, Sendable {
    case tuning
    case skipping
    case cantReachStreams
    case offline

    public var text: String {
        switch self {
        case .tuning: "TUNING…"
        case .skipping: "SKIPPING - UNAVAILABLE"
        case .cantReachStreams: "CAN'T REACH STREAMS - CLICK TO RETRY"
        case .offline: "OFFLINE"
        }
    }
}

/// Inputs to the machine: user actions, Picker and Resolver results, mpv events and network changes.
public enum SessionEvent: Equatable, Sendable {
    case selectGenre(GenreID)
    case next
    case play
    case pause
    case togglePause
    case stop
    /// "CLICK TO RETRY" after `failed`.
    case retry
    /// The PlaybackController's answer to a `.pick` effect (nil: nothing eligible).
    case picked(GenreID, StreamRef?)
    case resolved(StreamID)
    case resolveFailed(StreamID, FailureClass)
    /// The first non-silent audio of a loaded stream (the TTFA stamp).
    case started(StreamID)
    /// mpv reached the end of a finite stream.
    case endOfFile(StreamID)
    /// mpv failed to open or lost the stream.
    case playbackFailed(StreamID, FailureClass)
    case networkLost
    case networkRestored
    /// Play this stream now (Previous/history, favourites, an opened URL): like a pick the user made by hand.
    case playStream(StreamRef)
    /// The resolution can't be loaded for a while (`available_at` more than 3 s ahead, or no YouTube token): it is
    /// kept for later and the next pick plays. Not a failure (DESIGN §6.3).
    case resolveDeferred(StreamID)
    /// Rejoin the live edge of the current live stream or station (paused over 30 s, DESIGN §5.2): radio reloads,
    /// a resolved stream is resolved again (the controller's cache answers while the URL is still valid).
    case reloadCurrent
}

/// Outcome reported back for health (Picker) and source breakers (M6).
public enum PickOutcome: Equatable, Sendable {
    case success
    case failure(FailureClass)
}

/// Work for the PlaybackController. The machine never performs I/O, so all of playback logic is testable without mpv.
public enum SessionEffect: Equatable, Sendable {
    /// Ask the Picker for the next stream and answer with `.picked`. (An addition to DESIGN §4's list: picking
    /// needs live inputs only the controller has, such as the token bucket and the resolution cache.)
    case pick(GenreID, fastStart: Bool)
    case resolve(StreamRef)
    /// Load into mpv and play (unpausing if needed).
    case load(StreamRef)
    case pause(Bool)
    case stop
    /// Pre-resolve the genre's next pick (~10 s after first audio, DESIGN §6.3).
    case prefetch(GenreID)
    /// Save session.json (debounced by the controller).
    case persist
    case nowPlaying(PlaybackPhase, StreamRef?)
    case flash(FlashMessage)
    /// Feed health and breakers. (Also an addition to DESIGN §4's list, for the same reason as `.pick`.)
    case recordOutcome(StreamID, PickOutcome)
}

/// The session state the reducer works on.
public struct SessionState: Equatable, Sendable {
    public var phase: PlaybackPhase = .idle
    public var genre: GenreID?
    /// The stream being resolved, loaded or played.
    public var current: StreamRef?
    /// A `.pick` effect is outstanding.
    public var awaitingPick = false
    public var failuresInARow = 0
    /// Where to return when the network comes back.
    public var resumePhase: PlaybackPhase?

    public init() {}
}

/// The pure playback reducer (DESIGN §4): `(State, Event) → (State, [Effect])`. M1 scope: pick genre → resolve →
/// load → playing, next, pause, stop, failure → auto-advance, 5 failures in a row → failed, offline and back; plus
/// playing a given stream (Previous), deferred resolutions and the live-edge reload.
public enum SessionMachine {
    /// DESIGN §3: "5 failures in a row → Stop; CAN'T REACH STREAMS - CLICK TO RETRY".
    public static let maxFailuresInARow = 5

    public static func reduce(_ state: SessionState, _ event: SessionEvent) -> (SessionState, [SessionEffect]) {
        var s = state
        let effects = apply(&s, event)
        return (s, effects)
    }

    private static func apply(_ s: inout SessionState, _ event: SessionEvent) -> [SessionEffect] {
        switch event {
        case .selectGenre(let g):
            s.genre = g
            s.failuresInARow = 0
            if s.phase == .offline {
                s.current = nil
                s.awaitingPick = false
                s.resumePhase = .tuning
                return [.flash(.offline), .persist]
            }
            return startPick(&s, fastStart: true) + [.persist]

        case .next:
            guard s.genre != nil, s.phase != .offline else { return [] }
            s.failuresInARow = 0
            return startPick(&s, fastStart: false)

        case .retry:
            guard s.phase == .failed, s.genre != nil else { return [] }
            s.failuresInARow = 0
            return startPick(&s, fastStart: true)

        case .play:
            switch s.phase {
            case .paused:
                s.phase = .playing
                return [.pause(false), .nowPlaying(.playing, s.current), .persist]
            case .idle, .failed:
                guard s.genre != nil else { return [] }
                s.failuresInARow = 0
                return startPick(&s, fastStart: true)
            default:
                return []
            }

        case .pause:
            guard s.phase == .playing else { return [] }
            s.phase = .paused
            return [.pause(true), .nowPlaying(.paused, s.current), .persist]

        case .togglePause:
            return apply(&s, s.phase == .playing ? .pause : .play)

        case .stop:
            guard s.phase != .idle else { return [] }
            s.phase = .idle
            s.current = nil
            s.awaitingPick = false
            s.resumePhase = nil
            return [.stop, .nowPlaying(.idle, nil), .persist]

        case .picked(let g, let stream):
            guard s.phase == .tuning, s.awaitingPick, s.genre == g else { return [] }
            s.awaitingPick = false
            guard let stream else {
                return fail(&s)
            }
            s.current = stream
            if stream.isRadio {
                s.phase = .buffering
                return [.load(stream)]
            }
            return [.resolve(stream), .flash(.tuning)]

        case .resolved(let id):
            guard s.phase == .tuning, !s.awaitingPick, let cur = s.current, cur.id == id else { return [] }
            s.phase = .buffering
            return [.load(cur)]

        case .resolveFailed(let id, let failure):
            guard s.phase == .tuning, !s.awaitingPick, s.current?.id == id else { return [] }
            return failed(&s, id, failure)

        case .started(let id):
            guard s.phase == .buffering, let cur = s.current, cur.id == id else { return [] }
            s.phase = .playing
            s.failuresInARow = 0
            var effects: [SessionEffect] = [.recordOutcome(id, .success), .nowPlaying(.playing, cur), .persist]
            if let g = s.genre { effects.append(.prefetch(g)) }
            return effects

        case .endOfFile(let id):
            guard [.playing, .paused, .buffering].contains(s.phase), s.current?.id == id else { return [] }
            return startPick(&s, fastStart: false)

        case .playbackFailed(let id, let failure):
            guard [.buffering, .playing, .paused].contains(s.phase), s.current?.id == id else { return [] }
            return failed(&s, id, failure)

        case .networkLost:
            guard [.tuning, .buffering, .playing, .paused].contains(s.phase) else { return [] }
            s.resumePhase = s.phase == .paused ? .paused : .tuning
            s.phase = .offline
            s.awaitingPick = false
            return [.flash(.offline), .nowPlaying(.offline, s.current)]

        case .networkRestored:
            guard s.phase == .offline else { return [] }
            let resume = s.resumePhase ?? .tuning
            s.resumePhase = nil
            if resume == .paused, s.current != nil {
                s.phase = .paused
                return [.nowPlaying(.paused, s.current)]
            }
            guard let cur = s.current else {
                guard s.genre != nil else { s.phase = .idle; return [.nowPlaying(.idle, nil)] }
                return startPick(&s, fastStart: true)
            }
            // Retry the same stream: radio and live rejoin the live edge, a VOD URL may have died with the network.
            if cur.isRadio {
                s.phase = .buffering
                return [.load(cur)]
            }
            s.phase = .tuning
            s.awaitingPick = false
            return [.resolve(cur), .flash(.tuning)]

        case .playStream(let stream):
            guard s.phase != .offline else { return [] }
            // Without a genre yet, the stream's own genre is where Next and auto-advance continue.
            if s.genre == nil { s.genre = stream.genres.first }
            s.failuresInARow = 0
            s.current = stream
            s.awaitingPick = false
            s.resumePhase = nil
            if stream.isRadio {
                s.phase = .buffering
                return [.load(stream), .persist]
            }
            s.phase = .tuning
            return [.resolve(stream), .flash(.tuning), .persist]

        case .resolveDeferred(let id):
            guard s.phase == .tuning, !s.awaitingPick, s.current?.id == id else { return [] }
            return startPick(&s, fastStart: false)

        case .reloadCurrent:
            guard [.playing, .paused].contains(s.phase), let cur = s.current else { return [] }
            if cur.isRadio {
                s.phase = .buffering
                return [.load(cur)]
            }
            s.phase = .tuning
            return [.resolve(cur), .flash(.tuning)]
        }
    }

    private static func startPick(_ s: inout SessionState, fastStart: Bool) -> [SessionEffect] {
        guard let g = s.genre else {
            // Nothing to advance to: stop rather than wait for a pick that will never be asked for.
            guard s.phase != .idle else { return [] }
            s.phase = .idle
            s.current = nil
            s.awaitingPick = false
            return [.stop, .nowPlaying(.idle, nil)]
        }
        s.phase = .tuning
        s.current = nil
        s.awaitingPick = true
        s.resumePhase = nil
        return [.pick(g, fastStart: fastStart)]
    }

    /// A stream failed: count it, then advance or give up.
    private static func failed(_ s: inout SessionState, _ id: StreamID, _ failure: FailureClass) -> [SessionEffect] {
        s.failuresInARow += 1
        let report: SessionEffect = .recordOutcome(id, .failure(failure))
        if s.failuresInARow >= maxFailuresInARow { return [report] + fail(&s) }
        return [report, .flash(.skipping)] + startPick(&s, fastStart: false)
    }

    private static func fail(_ s: inout SessionState) -> [SessionEffect] {
        s.phase = .failed
        s.current = nil
        s.awaitingPick = false
        return [.stop, .flash(.cantReachStreams), .nowPlaying(.failed, nil), .persist]
    }
}
