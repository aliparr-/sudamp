// SPDX-License-Identifier: GPL-3.0-or-later
// The player state SkinUI draws (state in), the visualiser value the app adapts its analyser to, and the pure
// mapping onto SkinKit's composer state (WindowState). Window-level things (shade, scale, which windows are
// open, focus) are owned by WindowManager, not by this value.

import Foundation
import SkinKit

/// What the app tells the skinned windows to show. Plain values in app units; SkinUI converts to skin units.
nonisolated public struct SkinPlayerState: Equatable, Sendable {
    public enum PlayState: String, Codable, Sendable { case stopped, playing, paused }
    public enum TimeDisplay: String, Codable, Sendable { case elapsed, remaining }

    /// Source tag shown at the right of a playlist row (DESIGN §3).
    public enum SourceTag: String, Codable, Sendable, CaseIterable {
        case youtube = "YT", soundcloud = "SC", mixcloud = "MC", radio = "FM"
    }

    /// One station-list row.
    public struct PlaylistRow: Equatable, Sendable {
        public var tag: SourceTag?
        public var title: String
        /// Seconds; nil for live streams and radio.
        public var duration: Double?

        public init(tag: SourceTag? = nil, title: String, duration: Double? = nil) {
            self.tag = tag
            self.title = title
            self.duration = duration
        }
    }

    public struct Equalizer: Equatable, Sendable {
        /// The ON button.
        public var enabled = true
        public var auto = false
        /// dB, -12...12.
        public var preamp: Double = 0
        /// Ten gains in dB (-12...12), 60 Hz ... 16 kHz.
        public var bands: [Double] = [Double](repeating: 0, count: 10)

        public init(enabled: Bool = true, auto: Bool = false, preamp: Double = 0,
                    bands: [Double] = [Double](repeating: 0, count: 10)) {
            self.enabled = enabled
            self.auto = auto
            self.preamp = preamp
            self.bands = bands
        }
    }

    /// Marquee text, e.g. `[DEEP HOUSE] CREATOR - TITLE`, an ICY title or a status line.
    public var title = ""
    public var playState: PlayState = .stopped
    /// Tuning/buffering: the work indicator replaces the play-state light.
    public var working = false
    /// Seconds played.
    public var elapsed: Double = 0
    /// Seconds; nil for live streams and radio (no seek thumb, no remaining time).
    public var duration: Double?
    public var timeDisplay: TimeDisplay = .elapsed
    public var kbps: Int?
    public var khz: Int?
    /// true = stereo lit, false = mono lit, nil = neither.
    public var stereo: Bool?
    /// 0...1.
    public var volume: Double = 0.75
    /// -1 (left) ... 1 (right).
    public var balance: Double = 0
    public var equalizer = Equalizer()
    public var shuffle = false
    public var `repeat` = false
    public var playlist: [PlaylistRow] = []
    /// Index of the playing row.
    public var currentRow: Int?
    public var visualizerMode: VisualizerFrame.Mode = .spectrum
    /// "Always use the skin font": transliterate titles instead of the system-font overlay (DESIGN §8.3).
    public var alwaysSkinFont = false
    /// Duration text for live rows; nil leaves only the tag, as Winamp shows streams.
    public var liveLabel: String?

    public init() {}

    /// Seconds remaining, when the length is known.
    public var remaining: Double? {
        guard let duration, duration.isFinite else { return nil }
        return max(0, duration - max(0, elapsed))
    }
}

/// One visualiser frame from the app's analyser (the audio agent's vDSP output, adapted): pulled at 30 Hz.
nonisolated public struct VisualizerSnapshot: Equatable, Sendable {
    public static let barCount = VisualizerFrame.barCount
    public static let scopeCount = VisualizerFrame.scopeCount

    /// 19 bar heights, 0...1 (low to high frequency).
    public var bars: [Float]
    /// 76 oscilloscope samples, -1...1 (oldest first).
    public var scope: [Float]
    /// Optional peak heights 0...1; when nil SkinUI's PeakTracker computes falling peaks.
    public var peaks: [Float]?

    public init(bars: [Float], scope: [Float], peaks: [Float]? = nil) {
        self.bars = bars
        self.scope = scope
        self.peaks = peaks
    }

    public static let silent = VisualizerSnapshot(bars: [Float](repeating: 0, count: barCount),
                                                  scope: [Float](repeating: 0, count: scopeCount))
}

/// Called by SkinUI at up to 30 Hz while a visualiser is showing; nil draws silence.
public typealias VisualizerProvider = @MainActor () -> VisualizerSnapshot?

/// Slider values held by the view while (and just after) the user drags, so the thumb follows the mouse
/// before the app's next state arrives. App units.
nonisolated public struct SliderOverrides: Equatable, Sendable {
    public var volume: Double?
    public var balance: Double?
    /// Seek preview, 0...1.
    public var position: Double?
    /// dB.
    public var preamp: Double?
    /// Band index → dB.
    public var bands: [Int: Double] = [:]
    /// Playlist scrollbar, 0...1.
    public var scroll: Double?

    public init() {}

    public var isEmpty: Bool {
        volume == nil && balance == nil && position == nil && preamp == nil && bands.isEmpty && scroll == nil
    }

    /// Drops every override except the one for `control` (the slider still being dragged).
    public mutating func clear(keeping control: Control?) {
        var kept = SliderOverrides()
        switch control {
        case .volume?: kept.volume = volume
        case .balance?: kept.balance = balance
        case .position?: kept.position = position
        case .preamp?: kept.preamp = preamp
        case .playlistScrollbar?: kept.scroll = scroll
        case let c? where Control.bands.contains(c):
            let index = Control.bands.firstIndex(of: c)!
            if let db = bands[index] { kept.bands[index] = db }
        default: break
        }
        self = kept
    }
}

/// View-local state that the composer needs besides the player state: chrome, pressed control, marquee
/// scroll, blink phase, playlist scroll/selection and slider overrides.
nonisolated public struct SkinLocalState: Equatable, Sendable {
    public var focused = true
    /// Lights the main window's EQ / PL buttons.
    public var eqOpen = true
    public var playlistOpen = true
    /// Lights clutter-bar D.
    public var doubleSize = false
    /// region.txt shaping (the S1 kill switch turns it off: rectangular, fully opaque windows).
    public var applyRegion = true
    /// ≥ 2 device pixels per skin pixel: titles the skin font lacks get the Core Text overlay.
    public var systemFontAvailable = true
    public var pressed: Control?
    public var marqueeStep = 0
    public var marqueeDrag = 0
    public var blinkVisible = true
    public var playlistFirstRow = 0
    public var playlistSelected: [Int] = []
    public var overrides = SliderOverrides()

    public init() {}
}

/// SkinPlayerState + SkinLocalState → WindowState for one window, pure.
nonisolated public enum SkinStateMapper {
    public static func windowState(_ player: SkinPlayerState, kind: WindowKind, local: SkinLocalState) -> WindowState {
        var s = WindowState()
        s.window = kind
        s.focused = local.focused
        s.playback = switch player.playState {
        case .stopped: .stopped
        case .playing: .playing
        case .paused: .paused
        }
        s.working = player.working
        // Whole seconds: the composer floors anyway, so sub-second ticks never force a recompose.
        s.elapsed = player.elapsed.isFinite ? max(0, player.elapsed).rounded(.down) : 0
        if let duration = player.duration, duration.isFinite, duration > 0 { s.duration = duration }
        s.timeMode = player.timeDisplay == .remaining ? .remaining : .elapsed
        s.blinkVisible = local.blinkVisible
        s.title = player.title
        s.marqueeStep = local.marqueeStep
        s.marqueeDrag = local.marqueeDrag
        s.kbps = player.kbps
        s.khz = player.khz
        s.channels = player.stereo.map { $0 ? 2 : 1 } ?? 0
        s.volume = Int((unit(local.overrides.volume ?? player.volume) * 100).rounded())
        s.balance = Int((signedUnit(local.overrides.balance ?? player.balance) * 100).rounded())
        if let position = local.overrides.position, s.duration != nil { s.position = unit(position) }
        s.shuffle = player.shuffle
        s.repeat = player.repeat
        s.eqOpen = local.eqOpen
        s.playlistOpen = local.playlistOpen
        s.doubleSize = local.doubleSize
        s.pressed = local.pressed
        s.visualizer = nil  // a sublayer (DESIGN §8.1)

        // Only the EQ window draws EQ state and only the Playlist draws rows: other windows skip that work (this
        // runs for every refresh, several times a second).
        if kind == .eq || kind == .eqShade { s.eq = eqState(player, local) }
        if kind == .playlist { s.playlist = playlistState(player, local) }
        s.options = renderOptions(player, local)
        return s
    }

    static func eqState(_ player: SkinPlayerState, _ local: SkinLocalState) -> WindowState.EQState {
        var eq = WindowState.EQState()
        eq.on = player.equalizer.enabled
        eq.auto = player.equalizer.auto
        eq.preamp = EQSliderGeometry.value(forDecibels: local.overrides.preamp ?? player.equalizer.preamp)
        eq.bands = (0..<10).map { i in
            let db = local.overrides.bands[i] ?? (i < player.equalizer.bands.count ? player.equalizer.bands[i] : 0)
            return EQSliderGeometry.value(forDecibels: db.isFinite ? db : 0)
        }
        return eq
    }

    static func playlistState(_ player: SkinPlayerState, _ local: SkinLocalState) -> WindowState.PlaylistState {
        var playlist = WindowState.PlaylistState()
        playlist.rows = player.playlist.map { row in
            WindowState.PlaylistState.Row(title: row.title,
                                          duration: row.duration.map(rowDuration) ?? player.liveLabel,
                                          tag: row.tag?.rawValue)
        }
        playlist.current = player.currentRow.flatMap { $0 >= 0 && $0 < player.playlist.count ? $0 : nil }
        playlist.selected = local.playlistSelected.filter { $0 >= 0 && $0 < player.playlist.count }
        let maxFirst = maxFirstRow(rowCount: player.playlist.count)
        if let scroll = local.overrides.scroll {
            playlist.scroll = unit(scroll)
            playlist.firstRow = firstRow(forScroll: scroll, rowCount: player.playlist.count)
        } else {
            playlist.firstRow = min(max(local.playlistFirstRow, 0), maxFirst)
            playlist.scroll = maxFirst > 0 ? Double(playlist.firstRow) / Double(maxFirst) : 0
        }
        playlist.runningTime = runningTime(player.playlist, selected: playlist.selected)
        return playlist
    }

    static func renderOptions(_ player: SkinPlayerState, _ local: SkinLocalState) -> RenderOptions {
        var options = RenderOptions()
        options.alwaysSkinFont = player.alwaysSkinFont
        options.systemFontAvailable = local.systemFontAvailable
        options.applyRegion = local.applyRegion
        options.drawDynamicLayers = false
        return options
    }

    /// The largest first visible row for `rowCount` rows (13 visible).
    public static func maxFirstRow(rowCount: Int) -> Int {
        max(0, rowCount - PlaylistLayout.visibleRows)
    }

    public static func firstRow(forScroll scroll: Double, rowCount: Int) -> Int {
        Int((unit(scroll) * Double(maxFirstRow(rowCount: rowCount))).rounded())
    }

    /// Row lengths as Winamp shows them: minutes:seconds, minutes uncapped ("62:00").
    public static func rowDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// Hours:minutes:seconds when over an hour, else minutes:seconds.
    public static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded(.down))
        if total >= 3600 {
            return "\(total / 3600):" + String(format: "%02d:%02d", (total / 60) % 60, total % 60)
        }
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// Winamp's running-time readout: selected length / total length, "+" when some rows have no length.
    public static func runningTime(_ rows: [SkinPlayerState.PlaylistRow], selected: [Int]) -> String {
        guard !rows.isEmpty else { return "" }
        let total = rows.compactMap(\.duration).filter(\.isFinite).reduce(0, +)
        let chosen = selected.compactMap { $0 < rows.count ? rows[$0].duration : nil }.filter(\.isFinite).reduce(0, +)
        let unknown = rows.contains { $0.duration == nil }
        return clock(chosen) + "/" + clock(total) + (unknown ? "+" : "")
    }

    static func unit(_ v: Double) -> Double { v.isNaN ? 0 : min(max(v, 0), 1) }
    static func signedUnit(_ v: Double) -> Double { v.isNaN ? 0 : min(max(v, -1), 1) }
}

/// Converts analyser snapshots into SkinKit visualiser frames.
nonisolated public enum VisualizerAdapter {
    /// Bars 0...1 → 0...16 rows; scope -1...1 → rows 0 (top) ... 15; peaks from the snapshot or `tracker`.
    public static func frame(_ snapshot: VisualizerSnapshot?, mode: VisualizerFrame.Mode,
                             tracker: inout PeakTracker) -> VisualizerFrame {
        let snap = snapshot ?? .silent
        let bars = (0..<VisualizerFrame.barCount).map { i in
            i < snap.bars.count ? barHeight(snap.bars[i]) : 0
        }
        let scope = (0..<VisualizerFrame.scopeCount).map { i in
            scopeRow(i < snap.scope.count ? snap.scope[i] : 0)
        }
        let peaks: [Int]
        if let given = snap.peaks {
            peaks = (0..<VisualizerFrame.barCount).map { i in i < given.count ? barHeight(given[i]) : 0 }
        } else {
            peaks = tracker.update(bars: bars)
        }
        return VisualizerFrame(mode: mode, bars: bars, peaks: peaks, scope: scope)
    }

    public static func barHeight(_ value: Float) -> Int {
        guard value.isFinite else { return 0 }
        return Int((min(max(value, 0), 1) * 16).rounded())
    }

    public static func scopeRow(_ sample: Float) -> Int {
        guard sample.isFinite else { return 8 }
        let s = Double(min(max(sample, -1), 1))
        return Int(((1 - (s + 1) / 2) * 15).rounded())
    }
}

/// Falling peak markers for the spectrum (Winamp-style): a peak jumps up with its bar, holds briefly, then
/// falls at `fallPerFrame` rows per 30 Hz frame.
nonisolated public struct PeakTracker: Equatable, Sendable {
    public var holdFrames: Int
    public var fallPerFrame: Double
    private var peaks: [Double]
    private var hold: [Int]

    public init(holdFrames: Int = 8, fallPerFrame: Double = 0.5) {
        self.holdFrames = holdFrames
        self.fallPerFrame = fallPerFrame
        peaks = [Double](repeating: 0, count: VisualizerFrame.barCount)
        hold = [Int](repeating: 0, count: VisualizerFrame.barCount)
    }

    public mutating func update(bars: [Int]) -> [Int] {
        for i in 0..<peaks.count {
            let bar = Double(i < bars.count ? bars[i] : 0)
            if bar >= peaks[i] {
                peaks[i] = bar
                hold[i] = holdFrames
            } else if hold[i] > 0 {
                hold[i] -= 1
            } else {
                peaks[i] = max(bar, peaks[i] - fallPerFrame)
            }
        }
        return peaks.map { Int($0.rounded(.down)) }
    }

    public mutating func reset() {
        peaks = [Double](repeating: 0, count: peaks.count)
        hold = [Int](repeating: 0, count: hold.count)
    }
}
