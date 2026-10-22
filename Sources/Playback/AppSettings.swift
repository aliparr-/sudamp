// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Core
import Foundation
import Picker

/// `<profile>/settings.json`: the app's own preferences, kept per profile (UserDefaults is per bundle, not per
/// profile, and every app-level test runs in a fresh profile). The window layout (frames, scale, shade, always on
/// top) is SkinUI's `<profile>/layout.json`; everything else the skinned app restores is here (DESIGN §3
/// "Returning launch": skin, EQ, volume).
nonisolated public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// A gentle first-launch level (mixer gain (v/100)² = 0.64).
    public static let defaultVolume: Double = 80
    /// User presets kept from loaded `.eqf` files (newest last).
    public static let maxUserPresets = 50

    public var version = AppSettings.currentVersion
    /// 0...100, restored at launch (DESIGN §3 "Returning launch").
    public var volume: Double = AppSettings.defaultVolume
    /// -1 (left) ... 1 (right).
    public var balance: Double = 0
    /// DESIGN §13 default: on.
    public var autoResume = true
    /// The genre menu opens by itself once, on the first launch (DESIGN §3).
    public var genreMenuShown = false
    /// The chosen skin's id (`SkinLibrary`); nil is sudamp Dark.
    public var skin: String?
    /// EQ on/off, preamp and bands (restored at launch and applied before the first sound).
    public var equalizer = EQSettings()
    /// The EQ window's AUTO button (kept for the look; sudamp has no per-track presets).
    public var eqAuto = false
    /// The preset last chosen or loaded, for the presets menu's tick.
    public var eqPreset: String?
    /// Presets loaded from `.eqf` files, listed under the built-in ones.
    public var userPresets: [EQPreset] = []
    /// Shuffle (Surprise-genre mode) and Repeat (repeat the current mix).
    public var shuffle = false
    public var `repeat` = false
    /// The time display counts down (Winamp's click on the time).
    public var timeRemaining = false
    /// `spectrum`, `oscilloscope` or `off`.
    public var visualizer = "spectrum"
    /// region.txt shaping (spike S1's kill switch; on by default).
    public var regionEnabled = true
    /// Transliterate titles the skin font lacks instead of drawing them with the system font (DESIGN §8.3).
    public var alwaysSkinFont = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        // Lenient: a missing or bad field keeps its default.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? Self.currentVersion
        if let v = try? c.decode(Double.self, forKey: .volume), v.isFinite { volume = min(max(v, 0), 100) }
        if let b = try? c.decode(Double.self, forKey: .balance), b.isFinite { balance = min(max(b, -1), 1) }
        autoResume = (try? c.decode(Bool.self, forKey: .autoResume)) ?? true
        genreMenuShown = (try? c.decode(Bool.self, forKey: .genreMenuShown)) ?? false
        skin = (try? c.decode(String.self, forKey: .skin)).flatMap { $0.isEmpty ? nil : $0 }
        equalizer = (try? c.decode(EQSettings.self, forKey: .equalizer)) ?? EQSettings()
        eqAuto = (try? c.decode(Bool.self, forKey: .eqAuto)) ?? false
        eqPreset = try? c.decode(String.self, forKey: .eqPreset)
        userPresets = Array(((try? c.decode([EQPreset].self, forKey: .userPresets)) ?? []).suffix(Self.maxUserPresets))
        shuffle = (try? c.decode(Bool.self, forKey: .shuffle)) ?? false
        `repeat` = (try? c.decode(Bool.self, forKey: .repeat)) ?? false
        timeRemaining = (try? c.decode(Bool.self, forKey: .timeRemaining)) ?? false
        if let v = try? c.decode(String.self, forKey: .visualizer), Self.visualizerModes.contains(v) { visualizer = v }
        regionEnabled = (try? c.decode(Bool.self, forKey: .regionEnabled)) ?? true
        alwaysSkinFont = (try? c.decode(Bool.self, forKey: .alwaysSkinFont)) ?? false
    }

    public static let visualizerModes = ["spectrum", "oscilloscope", "off"]

    /// Adds (or replaces, by name) a user preset, keeping at most `maxUserPresets`.
    public mutating func addUserPreset(_ preset: EQPreset) {
        userPresets.removeAll { $0.name.caseInsensitiveCompare(preset.name) == .orderedSame }
        userPresets.append(preset)
        if userPresets.count > Self.maxUserPresets { userPresets.removeFirst(userPresets.count - Self.maxUserPresets) }
    }

    public static func file(_ paths: Paths) -> URL { paths.appSupport.appending(path: "settings.json") }

    public static func load(_ paths: Paths) -> AppSettings {
        StateFile.load(AppSettings.self, from: file(paths), maxVersion: currentVersion) ?? AppSettings()
    }

    public func save(_ paths: Paths) throws { try StateFile.save(self, to: Self.file(paths)) }
}
