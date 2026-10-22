// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation
import Picker

/// What sudamp publishes to the system's Now Playing (DESIGN §5.5), as plain data: Shell copies it into
/// `MPNowPlayingInfoCenter` (one key per field) and reports it back for `state.json`'s `.nowPlaying`.
nonisolated public struct NowPlayingInfo: Sendable, Equatable, Codable {
    /// `MPNowPlayingPlaybackState`'s cases.
    public enum State: String, Sendable, Codable {
        case unknown, playing, paused, stopped, interrupted
    }

    public var playbackState: State
    /// `MPMediaItemPropertyTitle`: the ICY title for radio when known, else the stream's title.
    public var title: String?
    /// `MPMediaItemPropertyArtist`: the creator (the station for radio).
    public var artist: String?
    /// `MPMediaItemPropertyAlbumTitle`: the genre.
    public var albumTitle: String?
    public var isLiveStream: Bool
    /// VOD only, seconds.
    public var duration: Double?
    public var elapsed: Double?
    /// 1 while playing, else 0.
    public var rate: Double
    /// `MPNowPlayingInfoPropertyExcludeFromSuggestions` (always true: these are not the user's library).
    public var excludeFromSuggestions: Bool
    public var streamId: String?
    /// `YT`, `SC`, `MC` or `FM`.
    public var sourceTag: String?

    public init(playbackState: State, title: String? = nil, artist: String? = nil, albumTitle: String? = nil,
                isLiveStream: Bool = false, duration: Double? = nil, elapsed: Double? = nil, rate: Double = 0,
                excludeFromSuggestions: Bool = true, streamId: String? = nil, sourceTag: String? = nil) {
        self.playbackState = playbackState
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.isLiveStream = isLiveStream
        self.duration = duration
        self.elapsed = elapsed
        self.rate = rate
        self.excludeFromSuggestions = excludeFromSuggestions
        self.streamId = streamId
        self.sourceTag = sourceTag
    }

    /// Phase → playback state: tuning, buffering and offline count as interrupted (a stream is on its way back),
    /// idle and failed as stopped.
    public static func state(for phase: PlaybackPhase) -> State {
        switch phase {
        case .playing: .playing
        case .paused: .paused
        case .tuning, .buffering, .offline: .interrupted
        case .idle, .failed: .stopped
        }
    }

    public static func from(_ s: PlayerSnapshot) -> NowPlayingInfo {
        let state: State = s.audioEngineError != nil ? .stopped : state(for: s.phase)
        guard let stream = s.stream else {
            return NowPlayingInfo(playbackState: state, title: state == .stopped ? nil : s.statusText,
                                  albumTitle: s.genreName)
        }
        let icy = stream.source == .radio ? s.icyTitle.flatMap { $0.isEmpty ? nil : $0 } : nil
        let duration = stream.isLive ? nil : (s.duration ?? stream.durationSec.map(Double.init))
        return NowPlayingInfo(
            playbackState: state, title: icy ?? stream.title,
            artist: stream.source == .radio && icy != nil ? PlainDisplay.stationName(stream) : stream.creator,
            albumTitle: s.genreName, isLiveStream: stream.isLive, duration: duration,
            elapsed: stream.isLive ? nil : s.position, rate: state == .playing ? 1 : 0, streamId: stream.id.rawValue,
            sourceTag: stream.tag)
    }

    /// Equal apart from the elapsed time (which the system extrapolates from `rate`).
    public func sameExceptElapsed(_ other: NowPlayingInfo) -> Bool {
        var a = self
        var b = other
        a.elapsed = nil
        b.elapsed = nil
        return a == b
    }
}
