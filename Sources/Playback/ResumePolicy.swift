// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Picker

/// What a returning launch plays (DESIGN §3 "Returning launch").
nonisolated public enum ResumePlan: Equatable, Sendable, CustomStringConvertible {
    /// Nothing plays until a pick.
    case none(reason: String)
    /// The genre's next bag item (fast start).
    case genre(GenreID)
    /// This stream again: a live stream at the live edge (`startAt` nil) or a VOD from its saved position.
    case stream(GenreID, StreamID, startAt: Double?)

    public var genre: GenreID? {
        switch self {
        case .none: nil
        case .genre(let g), .stream(let g, _, _): g
        }
    }

    public var description: String {
        switch self {
        case .none(let reason): "none (\(reason))"
        case .genre(let g): "genre \(g)"
        case let .stream(g, id, start): "stream \(id) in \(g)\(start.map { " at \(Int($0)) s" } ?? " (live edge)")"
        }
    }
}

/// The returning-launch rule (DESIGN §3): with auto-resume on (the default, §13) and the last session playing when
/// sudamp quit, the last genre resumes: a VOD from its saved position if quit under 6 h ago with over 5 min left,
/// a live stream or station at the live edge, else the genre's next bag item. A session that was paused or stopped
/// when sudamp quit stays quiet (the genre is still remembered for the Play button).
nonisolated public enum ResumePolicy {
    public static let maxAge: TimeInterval = 6 * 3600
    public static let minRemaining: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - engineReady: yt-dlp is usable; a non-radio stream needs it, so without it the genre's bag (radio) plays.
    public static func plan(last: LastSession?, catalog: FeedCatalog, now: Date, enabled: Bool = true,
                            engineReady: Bool) -> ResumePlan {
        guard enabled else { return .none(reason: "auto-resume is off") }
        guard let last else { return .none(reason: "nothing played before") }
        guard last.wasPlaying else { return .none(reason: "was not playing at quit") }
        guard catalog.genre(last.genre) != nil else { return .none(reason: "genre \(last.genre) is gone") }
        let g = last.genre
        guard let id = last.stream, let s = catalog[id], s.genres.contains(g) else { return .genre(g) }
        if !s.isRadio, !engineReady { return .genre(g) }
        if s.kind.isLive { return .stream(g, id, startAt: nil) }
        let age = now.timeIntervalSince(last.savedAt)
        guard age >= 0, age < maxAge, let position = last.positionSec, position.isFinite, position > 0 else {
            return .genre(g)
        }
        if let duration = s.durationSec, Double(duration) - position <= minRemaining { return .genre(g) }
        return .stream(g, id, startAt: position)
    }
}
