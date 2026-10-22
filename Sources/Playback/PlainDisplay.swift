// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Picker

/// The plain window's text (PLAN M2 PlainWindow), derived from a snapshot so it is unit-tested without AppKit:
/// a title line (`CREATOR - TITLE`, or the ICY title for radio), a detail line (source tag plus `LIVE` or
/// position/duration) and a status line (state, source, TTFA), plus the engine notice while yt-dlp downloads or
/// has failed (`PREPARING STREAM ENGINE 63%`, `ENGINE DOWNLOAD FAILED - RADIO ONLY`).
nonisolated public struct PlainDisplay: Sendable, Equatable {
    public var title: String
    public var detail: String
    public var status: String
    public var engineNotice: String?
    /// The transport button shows Pause while playing (or about to), else Play.
    public var showsPause: Bool
    /// A Retry button is useful: playback gave up, or the engine download failed.
    public var offersRetry: Bool
    /// The status line reads as a problem (drawn in a warning colour).
    public var isProblem: Bool

    public static let pickPrompt = "Pick a genre to start listening"

    /// - Parameters:
    ///   - muted: `--mute` / `SUDAMP_MUTE=1`: say so, so a silent app is never a mystery.
    ///   - lastGenreName: shown in the idle prompt when a previous session is remembered.
    public init(_ s: PlayerSnapshot, muted: Bool = false, lastGenreName: String? = nil) {
        let phase = s.phase
        let stream = s.stream
        if let stream {
            let icy = stream.source == .radio ? s.icyTitle.flatMap { $0.isEmpty ? nil : $0 } : nil
            title = icy ?? "\(stream.creator) - \(stream.title)"
        } else if phase == .idle, let lastGenreName {
            title = "Press Play for \(lastGenreName), or pick a genre"
        } else if phase == .idle {
            title = Self.pickPrompt
        } else {
            title = s.genreName.map { "\($0)" } ?? Self.pickPrompt
        }

        if let stream {
            var parts = [stream.tag]
            if stream.source == .radio, s.icyTitle?.isEmpty == false { parts.append(Self.stationName(stream)) }
            if stream.isLive {
                parts.append("LIVE")
            } else if let position = s.position {
                let duration = s.duration ?? stream.durationSec.map(Double.init)
                parts.append(duration.map { "\(Self.clock(position)) / \(Self.clock($0))" } ?? Self.clock(position))
            } else if let d = stream.durationSec {
                parts.append(Self.clock(Double(d)))
            }
            detail = parts.joined(separator: "  ·  ")
        } else {
            detail = ""
        }

        var problem = false
        let state: String
        if s.audioEngineError != nil {
            state = PlayerSnapshot.audioEngineErrorText
            problem = true
        } else {
            switch phase {
            case .idle: state = s.streamsStarted > 0 ? "STOPPED" : "READY"
            case .tuning, .buffering:
                state = s.statusText == FlashMessage.skipping.text ? FlashMessage.skipping.text : FlashMessage.tuning.text
                problem = state == FlashMessage.skipping.text
            case .playing: state = "PLAYING"
            case .paused: state = "PAUSED"
            case .offline: state = FlashMessage.offline.text; problem = true
            case .failed: state = FlashMessage.cantReachStreams.text; problem = true
            }
        }
        var parts = [state]
        if let stream, [.playing, .paused, .buffering].contains(phase) { parts.append(Self.sourceName(stream.source)) }
        if let t = s.lastTTFA, t.streamId == stream?.id, [.playing, .paused].contains(phase) {
            parts.append("TTFA \(Int(t.ms.rounded())) ms")
        }
        if muted { parts.append("MUTED") }
        status = parts.joined(separator: "  ·  ")

        engineNotice = s.engine.notice
        showsPause = [.playing, .tuning, .buffering].contains(phase)
        offersRetry = phase == .failed || s.engine.state == .failed
        isProblem = problem
    }

    /// `CREATOR - TITLE` for a station, or just one when they are the same (`Deep Radio`).
    public static func stationName(_ s: StreamInfo) -> String {
        s.creator.caseInsensitiveCompare(s.title) == .orderedSame || s.title.isEmpty ? s.creator : "\(s.creator) - \(s.title)"
    }

    /// `m:ss` under an hour, else `h:mm:ss`.
    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let (h, m, sec) = (t / 3600, (t % 3600) / 60, t % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    public static func sourceName(_ k: SourceKind) -> String {
        switch k {
        case .radio: "Radio"
        case .youtube: "YouTube"
        case .youtubeLive: "YouTube Live"
        case .soundcloud: "SoundCloud"
        case .mixcloud: "Mixcloud"
        }
    }
}
