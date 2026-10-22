// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Audio
import Catalog
import CryptoKit
import Foundation
import Picker
import Playback
import SkinKit
import SkinUI

/// The pictures a SkinView shows, at 1x and scaled up (nearest neighbour, as on screen).
enum SkinPicture {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// Base frame with the marquee and visualiser layers drawn in: what the layer tree shows, at 1x.
    static func composite(_ view: SkinView) -> Bitmap? {
        guard var frame = view.baseBitmap else { return nil }
        if view.kind == .main, let marquee = view.marqueeBitmap { frame.draw(marquee, at: MainLayout.marqueeText.origin) }
        if view.isVisualizerShown, let vis = view.visualizerBitmap {
            frame.draw(vis, at: view.kind == .shade ? ShadeLayout.visualizer.origin : MainLayout.visualizer.origin)
        }
        return frame
    }

    /// Every skin pixel as a `scale` × `scale` block.
    static func upscaled(_ bitmap: Bitmap, by scale: Int) -> Bitmap {
        guard scale > 1 else { return bitmap }
        let w = bitmap.width * scale, h = bitmap.height * scale
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let source = bitmap.pixels
        for y in 0..<h {
            let sy = y / scale
            for x in 0..<w {
                let s = (sy * bitmap.width + x / scale) * 4
                let d = (y * w + x) * 4
                pixels[d] = source[s]
                pixels[d + 1] = source[s + 1]
                pixels[d + 2] = source[s + 2]
                pixels[d + 3] = source[s + 3]
            }
        }
        return Bitmap(width: w, height: h, pixels: pixels)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One app state for `--snapshot` (PLAN M5 goldens, `Fixtures/states/app/*.json`): a player snapshot as the app sees
/// it, the station list, EQ and display preferences, which window at which scale, and the visualiser's frame. The
/// picture goes through the same mapping the running app uses (`SkinDisplay`) into an offscreen SkinView.
struct AppStateFixture: Decodable {
    struct Stream: Decodable {
        var id: String?
        var source: SourceKind
        var ref: String
        var title: String
        var creator: String
        var durationSec: Int?
        var kind: StreamKind?

        func streamRef(genre: GenreID?) throws -> StreamRef {
            guard Canonicaliser.url(source: source, ref: ref) != nil else {
                throw SkinPicture.Failure(description: "non-canonical \(source.rawValue) ref \(ref)")
            }
            let made = id.flatMap(StreamID.init(rawValue:)) ?? StreamID.make(source: source, ref: ref)
            guard let sid = made, sid.source == source else { throw SkinPicture.Failure(description: "bad stream id for \(ref)") }
            return StreamRef(id: sid, source: source, ref: ref, kind: kind ?? .default(for: source), title: title,
                             creator: creator, genres: genre.map { [$0] } ?? [], durationSec: durationSec)
        }
    }

    struct Equalizer: Decodable {
        var enabled: Bool?
        var preamp: Float?
        var bands: [Float]?
        /// A built-in preset's name instead of preamp and bands.
        var preset: String?
    }

    struct Visualizer: Decodable {
        /// 19 bars 0...1.
        var bars: [Float]?
        /// 76 samples -1...1.
        var scope: [Float]?
        var peaks: [Float]?
    }

    var skin: String?
    /// `main`, `shade`, `equalizer`, `eqShade`, `playlist`.
    var window: String
    var scale: Int?
    var focused: Bool?
    var phase: PlaybackPhase
    var genre: String?
    var genreName: String?
    /// Index into `streams` of what plays.
    var current: Int?
    var statusText: String?
    var icyTitle: String?
    var position: Double?
    var duration: Double?
    var volume: Double?
    var balance: Double?
    var kbps: Int?
    var sampleRate: Int?
    var channels: Int?
    /// `ready`, `installing` (with `engineProgress`), `failed`.
    var engine: String?
    var engineProgress: Double?
    var favouritesMode: Bool?
    var shuffle: Bool?
    var `repeat`: Bool?
    var streams: [Stream]?
    var equalizer: Equalizer?
    var timeRemaining: Bool?
    var visualizerMode: String?
    var eqAuto: Bool?
    var visualizer: Visualizer?
    var rememberedGenre: String?
    var firstRow: Int?
    var eqOpen: Bool?
    var playlistOpen: Bool?

    var role: SkinWindowRole {
        switch window {
        case "equalizer", "eq", "eqShade": .equalizer
        case "playlist": .playlist
        default: .main
        }
    }

    var shaded: Bool { window == "shade" || window == "eqShade" }

    func snapshot(streams refs: [StreamRef]) -> PlayerSnapshot {
        var engineStatus = EngineStatus(state: .ready, version: "2026.10.21")
        switch engine {
        case "installing"?: engineStatus = EngineStatus(state: .installing, progress: engineProgress ?? 0, download: "downloading")
        case "failed"?: engineStatus = EngineStatus(state: .failed, download: "unreachable")
        default: break
        }
        let stream = current.flatMap { $0 >= 0 && $0 < refs.count ? StreamInfo(refs[$0]) : nil }
        var s = PlayerSnapshot(
            phase: phase, genre: genre.flatMap(GenreID.init(rawValue:)), genreName: genreName, stream: stream,
            icyTitle: icyTitle, position: position, duration: duration, seekable: stream.map { !$0.isLive },
            engine: engineStatus, radioOnly: !engineStatus.isReady, statusText: statusText ?? PlayerSnapshot.idleText,
            volume: volume ?? AppSettings.defaultVolume, balance: balance ?? 0)
        if kbps != nil || sampleRate != nil || channels != nil {
            s.audioFormat = AudioFormatInfo(kbps: kbps, sampleRate: sampleRate, channels: channels)
        }
        s.favouritesMode = favouritesMode ?? false
        s.shuffleGenres = shuffle ?? false
        s.repeatStream = `repeat` ?? false
        return s
    }

    var equalizerSettings: EQSettings {
        if let name = equalizer?.preset, let preset = EQPresets.named(name) {
            return preset.settings(enabled: equalizer?.enabled ?? true)
        }
        return EQSettings(enabled: equalizer?.enabled ?? true, preamp: equalizer?.preamp ?? 0, bands: equalizer?.bands ?? [])
    }
}

/// `sudamp --snapshot <dir> --states <state.json> …` (PLAN M5): renders each app state offscreen, pixel-exact
/// through SkinKit and SkinUI, and writes `<dir>/<name>.png`, `.rgba` (raw RGBA8 at the state's scale) and `.sha256`
/// (of the RGBA bytes: PNG bytes vary between macOS versions). With a `goldens.json` next to the states, every hash
/// is compared and the exit status says whether all matched. Prints one JSON report.
enum AppSnapshot {
    struct Rendered {
        var name: String
        var bitmap: Bitmap
        var window: String
        var scale: Int
        var sha256: String { SkinPicture.sha256(bitmap.rgbaData) }
    }

    @MainActor
    static func render(_ fixture: AppStateFixture, name: String, library: SkinLibrary? = nil) throws -> Rendered {
        _ = NSApplication.shared
        let skinLibrary = library ?? SkinLibrary(bundledDirectory: SkinLibrary.defaultBundledDirectory(),
                                                 userDirectory: URL(filePath: "/nonexistent"))
        let skin = try resolveSkin(fixture.skin, library: skinLibrary)
        let genre = fixture.genre.flatMap(GenreID.init(rawValue:))
        let refs = try (fixture.streams ?? []).map { try $0.streamRef(genre: genre) }
        let snapshot = fixture.snapshot(streams: refs)
        let prefs = SkinPrefs(timeRemaining: fixture.timeRemaining ?? false,
                              visualizer: SkinPrefs.mode(fixture.visualizerMode ?? "spectrum"),
                              alwaysSkinFont: false, eqAuto: fixture.eqAuto ?? false)
        let state = SkinDisplay.playerState(snapshot, playlist: refs.map(StreamInfo.init),
                                            equalizer: fixture.equalizerSettings, prefs: prefs,
                                            rememberedGenre: fixture.rememberedGenre)
        let scale = SkinScale.clamp(fixture.scale ?? 1)
        let view = SkinView(role: fixture.role, skin: skin, scale: scale, shaded: fixture.shaded)
        let now = 100.0
        view.clock = { now }
        view.setFocused(fixture.focused ?? true)
        var chrome = SkinChrome()
        chrome.eqOpen = fixture.eqOpen ?? true
        chrome.playlistOpen = fixture.playlistOpen ?? true
        chrome.doubleSize = scale >= 2
        view.chrome = chrome
        let vis = fixture.visualizer
        view.visualizerProvider = {
            VisualizerSnapshot(bars: vis?.bars ?? [Float](repeating: 0, count: VisualizerSnapshot.barCount),
                               scope: vis?.scope ?? [Float](repeating: 0, count: VisualizerSnapshot.scopeCount),
                               peaks: vis?.peaks ?? [Float](repeating: 0, count: VisualizerSnapshot.barCount))
        }
        view.playerState = state
        if let first = fixture.firstRow { view.scrollPlaylist(toRow: first) }
        view.tick(now: now)
        guard let picture = SkinPicture.composite(view) else { throw SkinPicture.Failure(description: "nothing drawn") }
        return Rendered(name: name, bitmap: SkinPicture.upscaled(picture, by: scale), window: fixture.window, scale: scale)
    }

    static func resolveSkin(_ spec: String?, library: SkinLibrary) throws -> Skin {
        guard let spec, spec != SkinLibrary.builtInID else { return SudampDark.skin }
        if let entry = library.entry(id: spec) {
            switch library.load(entry) {
            case .success(let skin): return skin
            case .failure(let r): throw SkinPicture.Failure(description: "skin \(spec): \(r.reason)")
            }
        }
        switch SkinLibrary.loadFile(URL(filePath: ShellArguments.absolute(spec))) {
        case .success(let skin): return skin
        case .failure(let r): throw SkinPicture.Failure(description: "skin \(spec): \(r.reason)")
        }
    }

    static func load(_ path: String) throws -> AppStateFixture {
        try JSONDecoder().decode(AppStateFixture.self, from: Data(contentsOf: URL(filePath: path)))
    }

    /// The goldens next to the first state file, if any.
    static func goldens(near path: String) -> [String: String]? {
        let url = URL(filePath: path).deletingLastPathComponent().appending(path: "goldens.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    @MainActor
    static func run(directory: String, states: [String]) -> Int32 {
        let out = URL(filePath: ShellArguments.absolute(directory), directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("sudamp: cannot create \(out.path): \(error)\n".utf8))
            return 73
        }
        let goldens = states.first.flatMap(goldens(near:))
        var report: [[String: Any]] = []
        var ok = true
        for path in states where (path as NSString).lastPathComponent != "goldens.json" {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var entry: [String: Any] = ["name": name, "state": path]
            do {
                let rendered = try render(load(path), name: name)
                let base = out.appending(path: name)
                guard let png = rendered.bitmap.pngData() else { throw SkinPicture.Failure(description: "PNG encoding failed") }
                try png.write(to: base.appendingPathExtension("png"))
                try rendered.bitmap.rgbaData.write(to: base.appendingPathExtension("rgba"))
                let sha = rendered.sha256
                try Data((sha + "\n").utf8).write(to: base.appendingPathExtension("sha256"))
                entry["window"] = rendered.window
                entry["scale"] = rendered.scale
                entry["width"] = rendered.bitmap.width
                entry["height"] = rendered.bitmap.height
                entry["sha256"] = sha
                if let goldens {
                    let golden = goldens[name]
                    entry["golden"] = golden ?? NSNull()
                    entry["match"] = golden == sha
                    if golden != sha { ok = false }
                }
            } catch {
                entry["error"] = "\(error)"
                ok = false
            }
            report.append(entry)
        }
        let document: [String: Any] = ["ok": ok, "directory": out.path, "states": report,
                                       "compared": goldens != nil]
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys,
                                                                                      .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        return ok ? 0 : 1
    }
}
