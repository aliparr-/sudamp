// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Catalog
import Picker
import Playback
import SkinKit
import SkinUI

/// What the skinned windows show besides playback itself: settings.json's display preferences.
nonisolated struct SkinPrefs: Equatable, Sendable {
    var timeRemaining = false
    var visualizer: VisualizerFrame.Mode = .spectrum
    var alwaysSkinFont = false
    var eqAuto = false

    init(timeRemaining: Bool = false, visualizer: VisualizerFrame.Mode = .spectrum, alwaysSkinFont: Bool = false,
         eqAuto: Bool = false) {
        self.timeRemaining = timeRemaining
        self.visualizer = visualizer
        self.alwaysSkinFont = alwaysSkinFont
        self.eqAuto = eqAuto
    }

    init(_ settings: AppSettings) {
        self.init(timeRemaining: settings.timeRemaining, visualizer: Self.mode(settings.visualizer),
                  alwaysSkinFont: settings.alwaysSkinFont, eqAuto: settings.eqAuto)
    }

    static func mode(_ name: String) -> VisualizerFrame.Mode {
        switch name {
        case "oscilloscope": .oscilloscope
        case "off": .off
        default: .spectrum
        }
    }

    static func name(_ mode: VisualizerFrame.Mode) -> String {
        switch mode {
        case .spectrum: "spectrum"
        case .oscilloscope: "oscilloscope"
        case .off: "off"
        }
    }
}

/// The pure mapping from a `PlayerSnapshot` to what the skin draws (PLAN M5: title, time, kbps/kHz/stereo, play
/// state, volume, balance, EQ, shuffle/repeat, the station list), unit-tested without windows.
///
/// - Marquee: `[DEEP HOUSE] CREATOR - TITLE` or `[DEEP HOUSE] <ICY title>` (DESIGN §3); `*** CLICK HERE TO PICK A
///   GENRE ***` before anything has played; the failure texts of DESIGN §3's table; `[FAVOURITES]` while ★ Favourites
///   plays; the engine notice (`PREPARING STREAM ENGINE 63%`) is appended while only radio can play.
/// - Tuning and buffering light the work indicator; offline is stopped with the indicator on.
/// - VODs have a length (position slider, remaining time); live streams and radio have none.
/// - The playlist is the current genre's stations (banned ones left out), the playing one highlighted.
nonisolated enum SkinDisplay {
    /// The duration column of live rows (live streams and radio).
    static let liveLabel = "LIVE"
    static let separator = "  ***  "

    static func playerState(_ s: PlayerSnapshot, playlist: [StreamInfo], equalizer: EQSettings, prefs: SkinPrefs,
                            rememberedGenre: String? = nil) -> SkinPlayerState {
        var p = SkinPlayerState()
        p.title = title(s, rememberedGenre: rememberedGenre)
        switch s.phase {
        case .playing:
            p.playState = .playing
        case .paused:
            p.playState = .paused
        case .tuning, .buffering:
            p.playState = .playing
            p.working = true
        case .offline:
            p.playState = .stopped
            p.working = true
        case .idle, .failed:
            p.playState = .stopped
        }
        if s.audioEngineError != nil {
            p.playState = .stopped
            p.working = false
        }
        p.elapsed = [.playing, .paused].contains(s.phase) ? max(0, s.position ?? 0) : 0
        if let stream = s.stream, !stream.isLive, stream.source != .radio {
            if let d = s.duration, d.isFinite, d > 0 {
                p.duration = d
            } else if let d = stream.durationSec, d > 0 {
                p.duration = Double(d)
            }
        }
        p.timeDisplay = prefs.timeRemaining && p.duration != nil ? .remaining : .elapsed
        if [.playing, .paused].contains(s.phase), let format = s.audioFormat {
            p.kbps = format.kbps.flatMap { $0 > 0 ? min($0, 999) : nil }
            p.khz = format.sampleRate.flatMap { $0 > 0 ? min(Int((Double($0) / 1000).rounded()), 99) : nil }
            p.stereo = format.channels.map { $0 >= 2 }
        }
        p.volume = min(max(s.volume / 100, 0), 1)
        p.balance = min(max(s.balance, -1), 1)
        p.equalizer = SkinPlayerState.Equalizer(enabled: equalizer.enabled, auto: prefs.eqAuto,
                                                preamp: Double(equalizer.preamp), bands: equalizer.bands.map(Double.init))
        p.shuffle = s.shuffleGenres
        p.repeat = s.repeatStream
        p.playlist = playlistRows(playlist)
        p.currentRow = s.stream.flatMap { current in playlist.firstIndex { $0.id == current.id } }
        p.visualizerMode = prefs.visualizer
        p.alwaysSkinFont = prefs.alwaysSkinFont
        p.liveLabel = liveLabel
        return p
    }

    /// The genre label in square brackets, or nil when none applies.
    static func label(_ s: PlayerSnapshot) -> String? {
        if s.favouritesMode { return "[FAVOURITES]" }
        return s.genreName.map { "[\($0.uppercased())]" }
    }

    /// The marquee text.
    static func title(_ s: PlayerSnapshot, rememberedGenre: String? = nil) -> String {
        if s.audioEngineError != nil { return PlayerSnapshot.audioEngineErrorText }
        let notice = s.radioOnly ? s.engine.notice : nil
        func withNotice(_ text: String) -> String { notice.map { text + separator + $0 } ?? text }
        let labelled = { (text: String) in label(s).map { "\($0) \(text)" } ?? text }
        switch s.phase {
        case .idle:
            if s.genre != nil {
                return withNotice(labelled("STOPPED - PRESS PLAY, OR CLICK HERE TO PICK A GENRE"))
            }
            if let rememberedGenre {
                return withNotice("PRESS PLAY FOR \(rememberedGenre.uppercased()), OR CLICK HERE TO PICK A GENRE")
            }
            return withNotice(PlayerSnapshot.idleText)
        case .tuning, .buffering:
            return withNotice(labelled(s.statusText))
        case .playing, .paused:
            return withNotice(s.statusText)
        case .offline:
            return FlashMessage.offline.text
        case .failed:
            return FlashMessage.cantReachStreams.text
        }
    }

    static func tag(_ source: SourceKind) -> SkinPlayerState.SourceTag {
        switch source {
        case .youtube, .youtubeLive: .youtube
        case .soundcloud: .soundcloud
        case .mixcloud: .mixcloud
        case .radio: .radio
        }
    }

    /// One row per station: `CREATOR - TITLE` (a station's name), the source tag, and the length of a mix.
    static func playlistRows(_ streams: [StreamInfo]) -> [SkinPlayerState.PlaylistRow] {
        streams.map { s in
            let title = s.source == .radio ? PlainDisplay.stationName(s) : "\(s.creator) - \(s.title)"
            let duration = s.isLive || s.source == .radio ? nil : s.durationSec.map(Double.init)
            return SkinPlayerState.PlaylistRow(tag: tag(s.source), title: title, duration: duration)
        }
    }

    /// The stations the Playlist lists: ★ Favourites while they play, else the genre's, banned ones left out.
    static func playlist(genre: GenreID?, favouritesMode: Bool, catalog: FeedCatalog, favourites: [StreamRef],
                         banned: Set<StreamID>) -> [StreamInfo] {
        let streams: [StreamRef]
        if favouritesMode {
            streams = favourites
        } else if let genre {
            streams = catalog.streams(in: genre)
        } else {
            streams = []
        }
        return streams.filter { !banned.contains($0.id) }.map(StreamInfo.init)
    }
}
