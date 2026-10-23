// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Catalog
import ModernUI
import Picker
import Playback

/// The pure mapping from a `PlayerSnapshot` to what the modern skin shows (DESIGN §8.4), unit-tested without windows:
/// the classic marquee's single upper-case line becomes a title and subtitle in sentence case, and the status texts of
/// DESIGN §3's table become notices under them.
///
/// - Title: the track (`Sunset Sessions`) over its creator, or a radio station's ICY title over the station's name;
///   before anything plays, what to do (`Pick a genre to start listening`, `Press play for Deep House`).
/// - Notices, most important first: the audio engine error; can't reach streams (with Retry); offline; the stream
///   engine (`Preparing stream engine 63% · radio meanwhile`, `Engine download failed · radio only` with Retry);
///   a skipped stream; `--mute`.
/// - Tuning and buffering spin the play button. VODs have a length and can seek; live streams and radio show LIVE.
/// - The station list is the genre's streams (or ★ Favourites), banned ones left out, the playing one marked.
nonisolated enum ModernDisplay {
    struct Prefs: Equatable {
        var timeRemaining = false
        var visualizer = "spectrum"
        var eqPreset: String?
        var muted = false
    }

    static let idleTitle = "Pick a genre to start listening"
    static let idleSubtitle = "A random stream from a curated list plays right away"

    static func state(_ s: PlayerSnapshot, playlist: [StreamInfo], equalizer: EQSettings, prefs: Prefs,
                      rememberedGenre: String? = nil) -> ModernPlayerState {
        var m = ModernPlayerState()
        switch s.phase {
        case .playing: m.playback = .playing
        case .paused: m.playback = .paused
        case .tuning, .buffering:
            m.playback = .playing
            m.working = true
        case .idle, .offline, .failed: m.playback = .stopped
        }
        if s.audioEngineError != nil {
            m.playback = .stopped
            m.working = false
        }
        m.genre = s.favouritesMode ? "Favourites" : s.genreName
        m.genreKey = s.favouritesMode ? "favourites" : s.genre?.rawValue
        (m.title, m.subtitle) = lines(s, rememberedGenre: rememberedGenre)
        if let stream = s.stream, s.phase != .idle {
            m.source = tag(stream.source)
            m.isLive = stream.isLive || stream.source == .radio
        }
        m.elapsed = [.playing, .paused].contains(s.phase) ? max(0, s.position ?? 0) : 0
        if let stream = s.stream, !stream.isLive, stream.source != .radio, s.phase != .idle {
            if let d = s.duration, d.isFinite, d > 0 {
                m.duration = d
            } else if let d = stream.durationSec, d > 0 {
                m.duration = Double(d)
            }
        }
        m.canSeek = s.canSeek && m.duration != nil
        m.showsRemaining = prefs.timeRemaining && m.duration != nil
        if [.playing, .paused].contains(s.phase), let format = s.audioFormat { m.format = formatText(format) }
        (m.notice, m.offersRetry) = notice(s, muted: prefs.muted)
        m.volume = min(max(s.volume / 100, 0), 1)
        m.isFavourite = s.isFavourite
        m.canFavourite = s.stream != nil
        m.shuffle = s.shuffleGenres
        m.repeat = s.repeatStream
        m.equalizer = ModernPlayerState.Equalizer(enabled: equalizer.enabled, preamp: Double(equalizer.preamp),
                                                  bands: equalizer.bands.map(Double.init), preset: prefs.eqPreset)
        m.stationsTitle = s.favouritesMode ? "Favourites" : (s.genreName ?? "Stations")
        m.stations = stations(playlist)
        m.currentStation = s.stream.flatMap { current in playlist.firstIndex { $0.id == current.id } }
        m.visualizer = ModernPlayerState.Visualizer(rawValue: prefs.visualizer) ?? .spectrum
        return m
    }

    /// The title and subtitle.
    static func lines(_ s: PlayerSnapshot, rememberedGenre: String?) -> (String, String) {
        if s.audioEngineError != nil { return ("Audio engine error", "sudamp can't play until its audio engine works") }
        let genre = s.favouritesMode ? "Favourites" : s.genreName
        switch s.phase {
        case .idle:
            if s.genre != nil || s.favouritesMode {
                return ("Stopped", "Press play, or pick another genre")
            }
            if let rememberedGenre { return ("Press play for \(rememberedGenre)", "or pick a genre") }
            return (idleTitle, idleSubtitle)
        case .failed:
            return ("Can't reach streams", genre ?? "")
        case .tuning, .buffering, .playing, .paused, .offline:
            if let stream = s.stream { return streamLines(stream, icy: s.icyTitle) }
            if s.phase == .offline { return ("Offline", genre ?? "") }
            return ("Tuning…", genre ?? "")
        }
    }

    /// A stream's lines: the ICY title over the station for radio that sends one, else the title over the creator.
    static func streamLines(_ stream: StreamInfo, icy: String?) -> (String, String) {
        if stream.source == .radio {
            let station = PlainDisplay.stationName(stream)
            if let icy, !icy.isEmpty, icy.caseInsensitiveCompare(station) != .orderedSame { return (icy, station) }
            return (station, "Radio")
        }
        return (stream.title, stream.creator)
    }

    /// The notice under the title and whether Retry applies.
    static func notice(_ s: PlayerSnapshot, muted: Bool) -> (ModernPlayerState.Notice?, Bool) {
        if let error = s.audioEngineError { return (.problem("Audio engine error: \(error)"), false) }
        switch s.phase {
        case .failed: return (.problem("Several streams failed in a row"), true)
        case .offline: return (.problem("Offline · sudamp carries on by itself"), false)
        default: break
        }
        if s.radioOnly, let engine = engineNotice(s.engine) {
            return (engine, s.engine.state == .failed)
        }
        if [.tuning, .buffering].contains(s.phase), s.statusText == FlashMessage.skipping.text {
            return (.info("Skipped an unavailable stream"), false)
        }
        // While something plays its source and format matter more; muted is said before it starts.
        if muted, s.stream == nil { return (.info("Muted for this launch"), false) }
        return (nil, false)
    }

    /// The stream engine's state while only radio can play (EngineStatus.notice, in sentence case).
    static func engineNotice(_ e: EngineStatus) -> ModernPlayerState.Notice? {
        let percent = Int(((e.progress ?? 0) * 100).rounded())
        switch e.state {
        case .ready, .unknown, .checking, .disabled: return nil
        case .installing:
            return .info(e.purpose == "repair" ? "Updating stream engine \(percent)% · radio meanwhile"
                : "Preparing stream engine \(percent)% · radio meanwhile")
        case .missing, .corrupt: return .problem("Stream engine missing · radio only")
        case .failed:
            return .problem(e.download == "noSpace" ? "Stream engine needs 180 MB free · radio only"
                : "Engine download failed · radio only")
        }
    }

    /// `128 kbps · 48 kHz`, `· Mono` for one channel.
    static func formatText(_ f: AudioFormatInfo) -> String? {
        var parts: [String] = []
        if let kbps = f.kbps, kbps > 0 { parts.append("\(kbps) kbps") }
        if let rate = f.sampleRate, rate > 0 {
            let khz = Double(rate) / 1000
            parts.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        }
        if f.channels == 1 { parts.append("Mono") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func tag(_ source: SourceKind) -> ModernPlayerState.SourceTag {
        switch source {
        case .youtube, .youtubeLive: .youtube
        case .soundcloud: .soundcloud
        case .mixcloud: .mixcloud
        case .radio: .radio
        }
    }

    /// Station rows: title over creator for mixes, the station's name for radio; lengths for mixes only.
    static func stations(_ streams: [StreamInfo]) -> [ModernPlayerState.Station] {
        streams.map { s in
            let radio = s.source == .radio
            return ModernPlayerState.Station(tag: tag(s.source), title: radio ? PlainDisplay.stationName(s) : s.title,
                                             subtitle: radio ? "" : s.creator,
                                             duration: s.isLive || radio ? nil : s.durationSec.map(Double.init))
        }
    }
}
