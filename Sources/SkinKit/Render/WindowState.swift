// SPDX-License-Identifier: GPL-3.0-or-later
// Everything the composer needs to draw a window, as plain values. State fixtures (Fixtures/states/*.json) decode
// into this with every key optional, so a fixture lists only what it changes from the defaults.

import Foundation

public struct WindowState: Codable, Sendable, Equatable {
    public enum Playback: String, Codable, Sendable { case playing, paused, stopped }
    public enum TimeMode: String, Codable, Sendable { case elapsed, remaining }

    /// Optional window name; the CLI's `--window` wins over it.
    public var window: WindowKind?
    public var focused = true
    public var playback: Playback = .stopped
    /// Buffering/tuning: shows the work indicator instead of the play state.
    public var working = false
    /// Seconds played.
    public var elapsed: Double = 0
    /// Track length in seconds; nil for live streams and radio (no position thumb, no remaining time).
    public var duration: Double?
    public var timeMode: TimeMode = .elapsed
    /// Paused time blinks; false draws the "off" phase.
    public var blinkVisible = true
    public var title = ""
    public var marqueeStep = 0
    /// Extra marquee offset in pixels while the user drags it.
    public var marqueeDrag = 0
    public var kbps: Int?
    public var khz: Int?
    /// 1 = mono, 2 = stereo, 0 = unknown (neither lit).
    public var channels = 2
    /// 0...100.
    public var volume = 75
    /// -100 (left) ... 100 (right).
    public var balance = 0
    /// 0...1; defaults to elapsed / duration.
    public var position: Double?
    public var shuffle = false
    public var `repeat` = false
    public var eqOpen = true
    public var playlistOpen = true
    public var doubleSize = false
    /// The control held down, by `Control` raw value.
    public var pressed: Control?
    public var visualizer: VisualizerFrame?
    public var eq = EQState()
    public var playlist = PlaylistState()
    public var options = RenderOptions()

    public init() {}

    public struct EQState: Codable, Sendable, Equatable {
        public var on = true
        public var auto = false
        /// 0...100, 50 = 0 dB.
        public var preamp: Double = 50
        /// Ten values 0...100, 60 Hz to 16 kHz.
        public var bands: [Double] = [Double](repeating: 50, count: 10)

        public init() {}

        enum CodingKeys: String, CodingKey { case on, auto, preamp, bands }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true
            auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? false
            preamp = try c.decodeIfPresent(Double.self, forKey: .preamp) ?? 50
            bands = try c.decodeIfPresent([Double].self, forKey: .bands) ?? [Double](repeating: 50, count: 10)
        }
    }

    public struct PlaylistState: Codable, Sendable, Equatable {
        public struct Row: Codable, Sendable, Equatable {
            public var title: String
            /// "3:45"; nil for live entries.
            public var duration: String?
            /// Source tag: "YT", "SC", "MC" or "FM".
            public var tag: String?

            public init(title: String, duration: String? = nil, tag: String? = nil) {
                self.title = title
                self.duration = duration
                self.tag = tag
            }
        }

        public var rows: [Row] = []
        public var current: Int?
        public var selected: [Int] = []
        /// First visible row.
        public var firstRow = 0
        /// Scrollbar position 0...1.
        public var scroll: Double = 0
        /// Running-time readout, e.g. "0:00/1:02:05"; up to 18 characters.
        public var runningTime = ""
        /// An open pop-up menu: "add", "remove", "select", "misc" or "list".
        public var openMenu: String?
        /// Hovered entry of the open menu, top to bottom.
        public var menuHover: Int?

        public init() {}

        enum CodingKeys: String, CodingKey { case rows, current, selected, firstRow, scroll, runningTime, openMenu, menuHover }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rows = try c.decodeIfPresent([Row].self, forKey: .rows) ?? []
            current = try c.decodeIfPresent(Int.self, forKey: .current)
            selected = try c.decodeIfPresent([Int].self, forKey: .selected) ?? []
            firstRow = try c.decodeIfPresent(Int.self, forKey: .firstRow) ?? 0
            scroll = try c.decodeIfPresent(Double.self, forKey: .scroll) ?? 0
            runningTime = try c.decodeIfPresent(String.self, forKey: .runningTime) ?? ""
            openMenu = try c.decodeIfPresent(String.self, forKey: .openMenu)
            menuHover = try c.decodeIfPresent(Int.self, forKey: .menuHover)
        }
    }

    enum CodingKeys: String, CodingKey {
        case window, focused, playback, working, elapsed, duration, timeMode, blinkVisible, title, marqueeStep
        case marqueeDrag, kbps, khz, channels, volume, balance, position, shuffle, `repeat`, eqOpen, playlistOpen
        case doubleSize, pressed, visualizer, eq, playlist, options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowState()
        window = try c.decodeIfPresent(WindowKind.self, forKey: .window)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? d.focused
        playback = try c.decodeIfPresent(Playback.self, forKey: .playback) ?? d.playback
        working = try c.decodeIfPresent(Bool.self, forKey: .working) ?? d.working
        elapsed = try c.decodeIfPresent(Double.self, forKey: .elapsed) ?? d.elapsed
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        timeMode = try c.decodeIfPresent(TimeMode.self, forKey: .timeMode) ?? d.timeMode
        blinkVisible = try c.decodeIfPresent(Bool.self, forKey: .blinkVisible) ?? d.blinkVisible
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? d.title
        marqueeStep = try c.decodeIfPresent(Int.self, forKey: .marqueeStep) ?? d.marqueeStep
        marqueeDrag = try c.decodeIfPresent(Int.self, forKey: .marqueeDrag) ?? d.marqueeDrag
        kbps = try c.decodeIfPresent(Int.self, forKey: .kbps)
        khz = try c.decodeIfPresent(Int.self, forKey: .khz)
        channels = try c.decodeIfPresent(Int.self, forKey: .channels) ?? d.channels
        volume = try c.decodeIfPresent(Int.self, forKey: .volume) ?? d.volume
        balance = try c.decodeIfPresent(Int.self, forKey: .balance) ?? d.balance
        position = try c.decodeIfPresent(Double.self, forKey: .position)
        shuffle = try c.decodeIfPresent(Bool.self, forKey: .shuffle) ?? d.shuffle
        `repeat` = try c.decodeIfPresent(Bool.self, forKey: .repeat) ?? d.repeat
        eqOpen = try c.decodeIfPresent(Bool.self, forKey: .eqOpen) ?? d.eqOpen
        playlistOpen = try c.decodeIfPresent(Bool.self, forKey: .playlistOpen) ?? d.playlistOpen
        doubleSize = try c.decodeIfPresent(Bool.self, forKey: .doubleSize) ?? d.doubleSize
        pressed = try c.decodeIfPresent(Control.self, forKey: .pressed)
        visualizer = try c.decodeIfPresent(VisualizerFrame.self, forKey: .visualizer)
        eq = try c.decodeIfPresent(EQState.self, forKey: .eq) ?? d.eq
        playlist = try c.decodeIfPresent(PlaylistState.self, forKey: .playlist) ?? d.playlist
        options = try c.decodeIfPresent(RenderOptions.self, forKey: .options) ?? d.options
    }

    /// Seek position 0...1, or nil when there is nothing to show (stopped or live).
    public var effectivePosition: Double? {
        if let position { return clamped(position, 0, 1) }
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return clamped(clamped(elapsed, 0, 1e9).rounded(.down) / duration, 0, 1)
    }
}

/// Rendering choices that are not playback state.
public struct RenderOptions: Codable, Sendable, Equatable {
    /// Never switch the marquee to a system font; transliterate instead (DESIGN §8.3 "always skin font").
    public var alwaysSkinFont = false
    /// The view can show a Core Text overlay (≥ 2 device pixels per skin pixel); otherwise titles are
    /// transliterated into the skin font.
    public var systemFontAvailable = true
    /// Shape main/EQ windows with region.txt (behind spike S1's kill switch in the app).
    public var applyRegion = true
    /// Draw the marquee text and visualiser into the frame. SkinUI turns this off and draws them as sublayers
    /// (`WindowComposer.marqueeLayer`, `visualizerLayer`), so the base only recomposes on state changes.
    public var drawDynamicLayers = true

    public init() {}

    enum CodingKeys: String, CodingKey { case alwaysSkinFont, systemFontAvailable, applyRegion, drawDynamicLayers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alwaysSkinFont = try c.decodeIfPresent(Bool.self, forKey: .alwaysSkinFont) ?? false
        systemFontAvailable = try c.decodeIfPresent(Bool.self, forKey: .systemFontAvailable) ?? true
        applyRegion = try c.decodeIfPresent(Bool.self, forKey: .applyRegion) ?? true
        drawDynamicLayers = try c.decodeIfPresent(Bool.self, forKey: .drawDynamicLayers) ?? true
    }
}
