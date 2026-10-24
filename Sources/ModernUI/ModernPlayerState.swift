// SPDX-License-Identifier: GPL-3.0-or-later
// What the modern skin shows (state in) and what the user did (events out). ModernUI never acts on the player: the
// app maps its playback snapshot onto `ModernPlayerState` (Shell's `ModernDisplay`, unit-tested) and turns every
// `ModernEvent` into an action, as it does for the classic skins' SkinPlayerState and SkinControlEvent.

import CoreGraphics

nonisolated public struct ModernPlayerState: Equatable, Sendable {
    public enum Playback: String, Sendable { case stopped, playing, paused }

    public enum SourceTag: String, Sendable, CaseIterable {
        case youtube = "YT", soundcloud = "SC", mixcloud = "MC", radio = "FM"

        public var name: String {
            switch self {
            case .youtube: "YouTube"
            case .soundcloud: "SoundCloud"
            case .mixcloud: "Mixcloud"
            case .radio: "Radio"
            }
        }
    }

    /// A line under the title: something to know (the engine download) or something wrong (offline, failures).
    public enum Notice: Equatable, Sendable {
        case info(String)
        case problem(String)

        public var text: String {
            switch self {
            case .info(let t), .problem(let t): t
            }
        }

        public var isProblem: Bool { if case .problem = self { true } else { false } }
    }

    /// What the artwork shows: one of the scenes, every scene in turn (`rotate`), or just the artwork (`off`).
    public enum Visualizer: String, Sendable, CaseIterable {
        // In the menus' order, a section at a time (`section`).
        case spectrum, oscilloscope, leds, vuMeters = "vu-meters", heartbeat, turntable, speaker
        case halo, waterfall, tunnel, loops, pendulums, cells
        case starfield, synthwave, skyline, fireworks, aurora, rain, campfire, lava
        case pixelDJ = "pixel-dj", toast, breakfastBand = "breakfast-band", drummingCat = "drumming-cat", rally, demoscene
        case rotate, off

        public static let `default` = Visualizer.spectrum

        /// The scenes, in the order the menus list them.
        public static let scenes: [Visualizer] = allCases.filter(\.isScene)

        /// The order `rotate` plays the scenes in (and a click on the artwork walks): mixed up, so that neighbours
        /// differ (the menus' order would play seven meters in a row).
        public static let rotation: [Visualizer] = [
            .spectrum, .starfield, .pixelDJ, .loops, .synthwave, .vuMeters, .halo, .toast, .rain, .tunnel, .speaker,
            .skyline, .rally, .aurora, .leds, .fireworks, .drummingCat, .pendulums, .waterfall, .campfire,
            .breakfastBand, .turntable, .heartbeat, .cells, .lava, .demoscene, .oscilloscope,
        ]

        public var isScene: Bool { self != .rotate && self != .off }

        public var title: String {
            switch self {
            case .spectrum: "Spectrum"
            case .oscilloscope: "Oscilloscope"
            case .leds: "Retro LEDs"
            case .vuMeters: "VU Meters"
            case .heartbeat: "Heartbeat"
            case .turntable: "Turntable"
            case .speaker: "Speaker"
            case .halo: "Halo"
            case .waterfall: "Waterfall"
            case .tunnel: "Tunnel"
            case .loops: "Loops"
            case .pendulums: "Pendulums"
            case .cells: "Cells"
            case .starfield: "Starfield"
            case .synthwave: "Synthwave"
            case .skyline: "Skyline"
            case .fireworks: "Fireworks"
            case .aurora: "Aurora"
            case .rain: "Rain"
            case .campfire: "Campfire"
            case .lava: "Lava"
            case .pixelDJ: "Pixel DJ"
            case .toast: "Dancing Toast"
            case .breakfastBand: "Breakfast Band"
            case .drummingCat: "Drumming Cat"
            case .rally: "Rally"
            case .demoscene: "Demoscene"
            case .rotate: "Rotate"
            case .off: "Off"
            }
        }

        /// The SF Symbol that stands for it in the appearance popover (the toast's tile draws a slice of its own; there
        /// is no toast symbol).
        public var symbol: String {
            switch self {
            case .spectrum: "chart.bar.fill"
            case .oscilloscope: "waveform.path"
            case .leds: "square.grid.3x3.fill"
            case .vuMeters: "gauge.with.needle.fill"
            case .heartbeat: "waveform.path.ecg"
            case .turntable: "opticaldisc.fill"
            case .speaker: "hifispeaker.fill"
            case .halo: "sun.max.fill"
            case .waterfall: "water.waves"
            case .tunnel: "circle.circle"
            case .loops: "infinity"
            case .pendulums: "metronome.fill"
            case .cells: "circle.hexagongrid.fill"
            case .starfield: "sparkles"
            case .synthwave: "sun.horizon.fill"
            case .skyline: "building.2.fill"
            case .fireworks: "fireworks"
            case .aurora: "moon.stars.fill"
            case .rain: "cloud.rain.fill"
            case .campfire: "flame.fill"
            case .lava: "drop.fill"
            case .pixelDJ: "figure.dance"
            case .toast: "face.smiling.inverse"
            case .breakfastBand: "cup.and.saucer.fill"
            case .drummingCat: "cat.fill"
            case .rally: "gamecontroller.fill"
            case .demoscene: "sparkles.tv"
            case .rotate: "arrow.triangle.2.circlepath"
            case .off: "eye.slash"
            }
        }

        /// The menus' sections, in order, and the scenes under each.
        public enum Section: String, CaseIterable, Sendable {
            case meters = "Meters & Hi-Fi", shapes = "Shapes", places = "Places", characters = "Characters & Games"

            public var title: String { rawValue }
            public var scenes: [Visualizer] { Visualizer.scenes.filter { $0.section == self } }
        }

        /// The menu section a scene sits in (nil for `rotate` and `off`).
        public var section: Section? {
            switch self {
            case .spectrum, .oscilloscope, .leds, .vuMeters, .heartbeat, .turntable, .speaker: .meters
            case .halo, .waterfall, .tunnel, .loops, .pendulums, .cells: .shapes
            case .starfield, .synthwave, .skyline, .fireworks, .aurora, .rain, .campfire, .lava: .places
            case .pixelDJ, .toast, .breakfastBand, .drummingCat, .rally, .demoscene: .characters
            case .rotate, .off: nil
            }
        }

        /// A gentle scene, for a breakdown (Rotate turns to one when the music drops away, and to a lively one when it
        /// comes back).
        public var isCalm: Bool {
            switch self {
            case .oscilloscope, .turntable, .loops, .pendulums, .starfield, .aurora, .rain, .campfire, .lava: true
            default: false
            }
        }

        /// The next scene after this one in the rotation (clicking the artwork): `off` and `rotate` start at the first.
        public var nextScene: Visualizer {
            guard let i = Self.rotation.firstIndex(of: self) else { return Self.rotation[0] }
            return Self.rotation[(i + 1) % Self.rotation.count]
        }

        /// The scenes that suit a genre, best first, matched on words in its key like the artwork's colours
        /// (`lo-fi` brings the campfire and the rain). Empty for a genre with nothing in particular.
        public static func suited(toGenre key: String?) -> [Visualizer] {
            guard let lowered = key?.lowercased(), !lowered.isEmpty else { return [] }
            return genreScenes.first { lowered.contains($0.key) }?.scenes ?? []
        }

        /// Longest keys first, so `deep-house` wins over `house`.
        static let genreScenes: [(key: String, scenes: [Visualizer])] = [
            ("lo-fi", [.campfire, .rain, .drummingCat, .turntable, .skyline]),
            ("lofi", [.campfire, .rain, .drummingCat, .turntable, .skyline]),
            ("ambient", [.aurora, .rain, .lava, .starfield, .loops, .pendulums]),
            ("chill", [.rain, .aurora, .lava, .campfire, .turntable]),
            ("downtempo", [.lava, .rain, .turntable, .aurora, .skyline]),
            ("deep-house", [.skyline, .turntable, .lava, .halo, .synthwave, .pixelDJ]),
            ("house", [.pixelDJ, .toast, .breakfastBand, .speaker, .vuMeters, .fireworks]),
            ("disco", [.pixelDJ, .toast, .breakfastBand, .fireworks]),
            ("techno", [.tunnel, .cells, .waterfall, .heartbeat, .leds, .oscilloscope]),
            ("minimal", [.cells, .oscilloscope, .loops, .heartbeat]),
            ("trance", [.tunnel, .starfield, .halo, .aurora]),
            ("drum-and-bass", [.rally, .speaker, .tunnel, .fireworks, .starfield]),
            ("synthwave", [.synthwave, .skyline, .demoscene, .rally]),
            ("electro", [.demoscene, .synthwave, .rally, .cells]),
            ("jazz", [.turntable, .vuMeters, .drummingCat, .skyline]),
            ("soul", [.turntable, .vuMeters, .breakfastBand]),
            ("funk", [.breakfastBand, .turntable, .speaker]),
            ("classical", [.pendulums, .vuMeters, .aurora]),
            ("rock", [.speaker, .vuMeters, .fireworks]),
            ("hip-hop", [.turntable, .speaker, .skyline]),
        ].sorted { $0.key.count > $1.key.count }
    }

    /// A finish laid over whichever scene shows.
    public enum VisualizerEffect: String, Sendable, CaseIterable {
        case none, vhs, kaleidoscope

        public static let `default` = VisualizerEffect.none

        public var title: String {
            switch self {
            case .none: "None"
            case .vhs: "VHS"
            case .kaleidoscope: "Kaleidoscope"
            }
        }

        public var help: String {
            switch self {
            case .none: "The scene as it is"
            case .vhs: "An old video tape: scan lines, colour fringes and a tracking wobble on the kicks"
            case .kaleidoscope: "The scene mirrored six ways round the middle, turning slowly"
            }
        }
    }

    /// Seconds between scenes while the visualiser rotates.
    public static let visualizerIntervals: [Double] = [10, 20, 30, 60]
    public static let defaultVisualizerInterval: Double = 20

    /// One row of the station list.
    public struct Station: Equatable, Sendable {
        public var tag: SourceTag?
        public var title: String
        public var subtitle: String
        /// Seconds; nil for live streams and radio.
        public var duration: Double?

        public init(tag: SourceTag? = nil, title: String, subtitle: String = "", duration: Double? = nil) {
            self.tag = tag
            self.title = title
            self.subtitle = subtitle
            self.duration = duration
        }
    }

    public struct Equalizer: Equatable, Sendable {
        public static let bandCount = 10
        public static let range: ClosedRange<Double> = -12...12
        /// Centre frequencies, for the labels under the sliders.
        public static let bandLabels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]

        public var enabled = true
        /// dB, -12...12.
        public var preamp: Double = 0
        /// Ten gains in dB (-12...12), 60 Hz ... 16 kHz.
        public var bands = [Double](repeating: 0, count: bandCount)
        /// The preset last chosen, for the presets button.
        public var preset: String?

        public init(enabled: Bool = true, preamp: Double = 0, bands: [Double] = [Double](repeating: 0, count: 10),
                    preset: String? = nil) {
            self.enabled = enabled
            self.preamp = preamp
            self.bands = bands
            self.preset = preset
        }

        public var isFlat: Bool { preamp == 0 && bands.allSatisfy { $0 == 0 } }
    }

    public var playback: Playback = .stopped
    /// Tuning or buffering: the play button spins.
    public var working = false
    /// The main line: the track (or station) title, or a prompt while nothing plays.
    public var title = ""
    /// The creator or station name, or what to do next.
    public var subtitle = ""
    /// The genre playing, nil while none is chosen (the genre button then asks for one).
    public var genre: String?
    /// The genre's stable key (its id), which picks the artwork's colours.
    public var genreKey: String?
    public var source: SourceTag?
    public var isLive = false
    /// Seconds played.
    public var elapsed: Double = 0
    /// Seconds; nil for live streams and radio.
    public var duration: Double?
    public var canSeek = false
    /// The right-hand time counts down.
    public var showsRemaining = false
    /// `128 kbps · 48 kHz`, while something plays.
    public var format: String?
    public var notice: Notice?
    public var offersRetry = false
    /// 0...1.
    public var volume: Double = 0.8
    public var isFavourite = false
    public var canFavourite = false
    public var shuffle = false
    public var `repeat` = false
    public var equalizer = Equalizer()
    /// The station list's heading (the genre, or Favourites).
    public var stationsTitle = ""
    public var stations: [Station] = []
    /// The playing row.
    public var currentStation: Int?
    public var visualizer: Visualizer = .default
    /// Seconds each scene shows while the visualiser rotates.
    public var visualizerInterval: Double = ModernPlayerState.defaultVisualizerInterval
    /// What colours the artwork behind the visualiser.
    public var artworkColors: ArtworkColors = .default
    /// A finish over the scene.
    public var visualizerEffect: VisualizerEffect = .default

    public init() {}

    /// Seconds remaining, when the length is known.
    public var remaining: Double? {
        guard let duration, duration.isFinite else { return nil }
        return max(0, duration - max(0, elapsed))
    }

    /// 0...1 through the track, when the length is known.
    public var progress: Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return min(max(elapsed / duration, 0), 1)
    }

    /// Whether the artwork animates (the visualiser and the light inside it).
    public var isAnimating: Bool { playback == .playing && !working }

    /// `m:ss` under an hour, else `h:mm:ss`.
    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let (h, m, s) = (t / 3600, (t % 3600) / 60, t % 60)
        return h > 0 ? "\(h):" + pad(m) + ":" + pad(s) : "\(m):" + pad(s)
    }

    private static func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
}

/// One visualiser frame from the app's analyser: pulled 30 times a second while the artwork animates.
nonisolated public struct ModernVisualizerFrame: Equatable, Sendable {
    public static let barCount = 19
    public static let scopeCount = 76

    /// Bar levels 0...1, low to high frequency.
    public var bars: [Float]
    /// Peak markers 0...1 over the bars (they hold, then fall).
    public var peaks: [Float]
    /// Oscilloscope samples -1...1, oldest first.
    public var scope: [Float]

    public init(bars: [Float], peaks: [Float]? = nil, scope: [Float]) {
        self.bars = bars
        self.peaks = peaks ?? bars
        self.scope = scope
    }

    public static let silent = ModernVisualizerFrame(bars: [Float](repeating: 0, count: barCount),
                                                     scope: [Float](repeating: 0, count: scopeCount))
}

public typealias ModernVisualizerProvider = @MainActor () -> ModernVisualizerFrame?

/// The cards that open under the player.
nonisolated public enum ModernPanel: String, CaseIterable, Sendable {
    case equalizer, stations

    public var title: String {
        switch self {
        case .equalizer: "Equalizer"
        case .stations: "Stations"
        }
    }
}

/// Everything a user can do to the modern window. Screen points are AppKit global coordinates (origin bottom-left of
/// the primary display), ready for `NSMenu.popUp(positioning:at:in: nil)`: the top-left of the menu.
nonisolated public enum ModernEvent: Equatable, Sendable, CustomStringConvertible {
    case playPause, stop, next, previous
    /// Released on the progress bar: 0...1 of the track (only sent while it can seek).
    case seek(Double)
    /// 0...1, sent continuously while dragging.
    case volume(Double)
    case favourite
    case retry
    case toggleTimeDisplay
    /// A click on the artwork: the next scene (while rotating, the rotation skips ahead by itself).
    case cycleVisualizer
    case setVisualizer(ModernPlayerState.Visualizer)
    /// Seconds per scene while rotating.
    case setVisualizerInterval(Double)
    case setVisualizerEffect(ModernPlayerState.VisualizerEffect)
    case setArtworkColors(ArtworkColors)
    case toggleShuffle
    case toggleRepeat
    case genreMenu(CGPoint)
    case moreMenu(CGPoint)
    case contextMenu(CGPoint)
    case presetsMenu(CGPoint)
    case eqEnabled(Bool)
    /// Band 0...9 in dB, sent continuously while dragging.
    case eqBand(Int, Double)
    case preamp(Double)
    /// Every band and the preamp back to 0 dB.
    case eqReset
    /// Double-click or Return on a station row.
    case playStation(Int)
    case setAppearance(ModernAppearance)
    case setTint(ModernTint)
    case switchToClassic
    /// A panel opened or closed, or the window moved: save the layout, publish the state.
    case layoutChanged
    case close
    case minimize

    public var description: String {
        func p(_ point: CGPoint) -> String { "@\(Int(point.x.rounded())),\(Int(point.y.rounded()))" }
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        switch self {
        case .playPause: return "playPause"
        case .stop: return "stop"
        case .next: return "next"
        case .previous: return "previous"
        case .seek(let v): return "seek(\(f(v)))"
        case .volume(let v): return "volume(\(f(v)))"
        case .favourite: return "favourite"
        case .retry: return "retry"
        case .toggleTimeDisplay: return "toggleTimeDisplay"
        case .cycleVisualizer: return "cycleVisualizer"
        case .setVisualizer(let v): return "setVisualizer(\(v.rawValue))"
        case .setVisualizerEffect(let e): return "setVisualizerEffect(\(e.rawValue))"
        case .setVisualizerInterval(let s): return "setVisualizerInterval(\(Int(s)) s)"
        case .setArtworkColors(let c): return "setArtworkColors(\(c.rawValue))"
        case .toggleShuffle: return "toggleShuffle"
        case .toggleRepeat: return "toggleRepeat"
        case .genreMenu(let pt): return "genreMenu\(p(pt))"
        case .moreMenu(let pt): return "moreMenu\(p(pt))"
        case .contextMenu(let pt): return "contextMenu\(p(pt))"
        case .presetsMenu(let pt): return "presetsMenu\(p(pt))"
        case .eqEnabled(let on): return "eqEnabled(\(on))"
        case .eqBand(let i, let db): return "eqBand(\(i), \(f(db)) dB)"
        case .preamp(let db): return "preamp(\(f(db)) dB)"
        case .eqReset: return "eqReset"
        case .playStation(let i): return "playStation(\(i))"
        case .setAppearance(let a): return "setAppearance(\(a.rawValue))"
        case .setTint(let t): return "setTint(\(t.rawValue))"
        case .switchToClassic: return "switchToClassic"
        case .layoutChanged: return "layoutChanged"
        case .close: return "close"
        case .minimize: return "minimize"
        }
    }
}

/// The modern window's controls by name, for automation (`pressControl`, `dragSlider`).
nonisolated public enum ModernControl: String, CaseIterable, Sendable {
    case play, pause, playPause, stop, next, previous, favourite, genre, more, retry
    case equalizerButton, stationsButton, appearanceButton
    case volume, position, preamp
    case eqToggle, presets, eqReset
    case eq0, eq1, eq2, eq3, eq4, eq5, eq6, eq7, eq8, eq9

    public static let bands: [ModernControl] = [.eq0, .eq1, .eq2, .eq3, .eq4, .eq5, .eq6, .eq7, .eq8, .eq9]

    public var bandIndex: Int? { Self.bands.firstIndex(of: self) }
}
