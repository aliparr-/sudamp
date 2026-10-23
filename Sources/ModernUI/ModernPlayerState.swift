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

    public enum Visualizer: String, Sendable, CaseIterable { case spectrum, oscilloscope, off }

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
    public var visualizer: Visualizer = .spectrum

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

/// One visualiser frame from the app's analyser: pulled at 30 Hz while the artwork animates.
nonisolated public struct ModernVisualizerFrame: Equatable, Sendable {
    public static let barCount = 19
    public static let scopeCount = 76

    /// Bar levels 0...1, low to high frequency.
    public var bars: [Float]
    /// Oscilloscope samples -1...1, oldest first.
    public var scope: [Float]

    public init(bars: [Float], scope: [Float]) {
        self.bars = bars
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
    case cycleVisualizer
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
