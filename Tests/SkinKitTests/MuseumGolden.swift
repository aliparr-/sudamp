// SPDX-License-Identifier: GPL-3.0-or-later
// The museum golden metric (PLAN M4/M7 `make golden`; tracked, not a gate): SkinKit renders each corpus skin's Main
// and EQ windows in Webamp's screenshot state and compares them, pixel by pixel outside the masked dynamic areas,
// with the Skin Museum's screenshot of the same skin (275x348: Main, EQ and Playlist stacked at 1x).
//
// The screenshot state is Webamp's `packages/webamp-demo/js/screenshotInitialState.ts` @ 7734cd3 (MIT © 2015
// Jordan Eldredge; values only) on top of its reducer defaults: playing, 3 s into a 5 s track ("DJ Mike Llama -
// Llama Whipping Intro"), 128 kbps / 44 kHz stereo, volume round(200/255*100) = 78, balance 0, EQ on with the
// sliders below, Main focused (so the EQ title bar is the inactive one), EQ and Playlist open. Shuffle, repeat and
// EQ auto are drawn *selected* in the screenshots, although the state file and Webamp's reducers default them to
// off: 98 of the first 100 corpus skins show the selected sprites (docs/spikes/golden.md), so the state follows the
// screenshots.
//
// Masks (docs/research/findings-skins.md "missed considerations"): the visualiser and the marquee text are live in
// screenshots, and the clock is masked as well, as PLAN asks. Only complete skins are scored (no sheet from the
// fallback skin in either window), since Webamp drew its Nullsoft base skin where sudamp draws sudamp Dark.
//
// `scripts/golden-fetch.sh` fills the corpus; `scripts/golden-compare.sh` runs `MuseumGoldenHarness` with
// SKINKIT_GOLDEN=1, which writes report.json, summary.md, heat maps and per-skin comparison strips next to it.
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SkinKit

/// Webamp's museum screenshot: where the windows are and the state they show.
enum MuseumScreenshot {
    static let size = IntSize(275, 348)
    static let windows: [WindowKind] = [.main, .eq]
    /// EQ sliders 60 Hz … 16 kHz, 0…100 with 50 = 0 dB (screenshotInitialState.ts).
    static let eqBands: [Double] = [52, 74, 83, 91, 80, 54, 23, 19, 34, 75]
    static let preamp: Double = 56
    static let title = "1. DJ Mike Llama - Llama Whipping Intro (0:05)"

    /// The window's rect in the stacked screenshot (main at the top, EQ under it, playlist last).
    static func frame(_ window: WindowKind) -> IntRect {
        switch window {
        case .eq: return IntRect(0, 116, 275, 116)
        case .playlist: return IntRect(0, 232, 275, 116)
        default: return IntRect(0, 0, 275, 116)
        }
    }

    static func state(_ window: WindowKind) -> WindowState {
        var s = WindowState()
        s.window = window
        s.focused = window == .main
        s.playback = .playing
        s.elapsed = 3
        s.duration = 5
        s.title = title
        s.kbps = 128
        s.khz = 44
        s.channels = 2
        s.volume = 78
        s.balance = 0
        s.eqOpen = true
        s.playlistOpen = true
        // Observed in the screenshots (see the header), not in screenshotInitialState.ts.
        s.shuffle = true
        s.repeat = true
        s.eq.on = true
        s.eq.auto = true
        s.eq.preamp = preamp
        s.eq.bands = eqBands
        // The marquee is masked; keep it on the skin font so nothing depends on the system-font path.
        s.options.alwaysSkinFont = true
        return s
    }

    /// Areas left out of the comparison, in window pixels.
    static func masks(_ window: WindowKind) -> [IntRect] {
        switch window {
        case .main:
            return [
                MainLayout.visualizer,
                // The marquee text, one column wider than SkinKit's 154: Webamp drew 155 px until 2021-04-30
                // (captbaritone/webamp 309c2710 "Fix marquee width"), and most screenshots are older than that.
                MainLayout.marqueeText.with(width: MainLayout.marqueeText.width + 1),
                // Both minus positions and all four digits: x 38 (minus) to 99 (last digit's right edge).
                IntRect(MainLayout.minusNumbers.x, MainLayout.digitY, MainLayout.digitX[3] + MainLayout.digitSize.width - MainLayout.minusNumbers.x, MainLayout.digitSize.height),
            ]
        default:
            return []
        }
    }
}

/// How one window's render compares with its screenshot crop.
struct GoldenDiff: Codable, Equatable, Sendable {
    /// Pixels compared (window area minus masks).
    var compared: Int
    /// Compared pixels that differ: opacity differs, or both opaque and a channel differs by more than the tolerance.
    var differing: Int
    /// Of `differing`, pixels where one side is transparent and the other is not (region.txt shaping).
    var opacityMismatches: Int
    /// Largest channel difference over pixels opaque on both sides.
    var maxDelta: Int

    var share: Double { compared == 0 ? 0 : Double(differing) / Double(compared) }
}

enum GoldenCompare {
    /// A pixel counts as opaque from alpha 128 up (Webamp's SVG clip path may anti-alias region edges).
    static func isOpaque(_ p: RGBA) -> Bool { p.a >= 128 }

    /// Compares `rendered` with `reference` (same size) outside `masks`. Returns the counts and a per-pixel map of
    /// differing pixels (row-major, `true` = differs; masked pixels are `false`).
    static func compare(_ rendered: Bitmap, _ reference: Bitmap, masks: [IntRect], tolerance: Int = 0) -> (diff: GoldenDiff, map: [Bool]) {
        precondition(rendered.size == reference.size, "compare needs equal sizes")
        let w = rendered.width, h = rendered.height
        var masked = [Bool](repeating: false, count: w * h)
        for rect in masks {
            let r = rect.intersection(rendered.bounds)
            guard !r.isEmpty else { continue }
            for y in r.minY..<r.maxY { for x in r.minX..<r.maxX { masked[y * w + x] = true } }
        }
        var map = [Bool](repeating: false, count: w * h)
        var diff = GoldenDiff(compared: 0, differing: 0, opacityMismatches: 0, maxDelta: 0)
        for y in 0..<h {
            for x in 0..<w where !masked[y * w + x] {
                diff.compared += 1
                let a = rendered[x, y], b = reference[x, y]
                let ao = isOpaque(a), bo = isOpaque(b)
                if !ao && !bo { continue }
                if ao != bo {
                    diff.differing += 1
                    diff.opacityMismatches += 1
                    map[y * w + x] = true
                    continue
                }
                let delta = max(abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b)))
                diff.maxDelta = max(diff.maxDelta, delta)
                if delta > tolerance {
                    diff.differing += 1
                    map[y * w + x] = true
                }
            }
        }
        return (diff, map)
    }

    /// The control (or "background") each differing pixel lies on, for triage.
    static func attribute(_ map: [Bool], window: WindowKind) -> [String: Int] {
        let size = window.size
        var counts: [String: Int] = [:]
        for y in 0..<size.height {
            for x in 0..<size.width where map[y * size.width + x] {
                counts[Layout.hitTest(window, IntPoint(x, y))?.rawValue ?? "background", default: 0] += 1
            }
        }
        return counts
    }
}

enum ScreenshotDecoder {
    enum Failure: Error { case undecodable }

    /// Decodes a PNG keeping its alpha (straight, sRGB). Museum screenshots are transparent outside region shapes.
    static func decode(_ data: Data) throws -> Bitmap {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw Failure.undecodable }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw Failure.undecodable }
        // Un-premultiply; opaque pixels (all that the metric compares by colour) come back exact.
        var i = 0
        while i < pixels.count {
            let a = Int(pixels[i + 3])
            if a > 0 && a < 255 {
                for k in 0..<3 { pixels[i + k] = UInt8(min(255, (Int(pixels[i + k]) * 255 + a / 2) / a)) }
            }
            i += 4
        }
        return Bitmap(width: w, height: h, pixels: pixels)
    }
}

// MARK: - Unit tests (always run)

@Suite struct MuseumScreenshotStateTests {
    @Test func stateMatchesWebampsScreenshotState() {
        let main = MuseumScreenshot.state(.main)
        #expect(main.playback == .playing && main.focused)
        #expect(main.volume == 78 && main.balance == 0)
        #expect(main.effectivePosition == 0.6)
        #expect(main.kbps == 128 && main.khz == 44 && main.channels == 2)
        #expect(main.shuffle && main.repeat)   // as the screenshots show them
        let eq = MuseumScreenshot.state(.eq)
        #expect(!eq.focused)
        #expect(eq.eq.on && eq.eq.auto)
        #expect(eq.eq.bands == [52, 74, 83, 91, 80, 54, 23, 19, 34, 75] && eq.eq.preamp == 56)
    }

    @Test func masksCoverTheDynamicAreasAndNothingElse() {
        let masks = MuseumScreenshot.masks(.main)
        func covered(_ p: IntPoint) -> Bool { masks.contains { $0.contains(p) } }
        for rect in [MainLayout.visualizer, MainLayout.marqueeText] {
            for p in [rect.origin, IntPoint(rect.maxX - 1, rect.maxY - 1)] { #expect(covered(p), "\(p)") }
        }
        // Minus sign (numbers.bmp and nums_ex.bmp positions) and every digit cell.
        #expect(covered(IntPoint(38, 32)) && covered(IntPoint(38, 26)))
        for x in MainLayout.digitX { #expect(covered(IntPoint(x, 26)) && covered(IntPoint(x + 8, 38))) }
        #expect(covered(IntPoint(265, 30)))   // the screenshot-era 155th marquee column
        // Static parts stay compared: the play state, kbps, title bar, transport, position bar, right of the marquee.
        for p in [IntPoint(27, 29), IntPoint(112, 44), IntPoint(130, 5), IntPoint(20, 90), IntPoint(100, 75), IntPoint(37, 32),
                  IntPoint(266, 30)] {
            #expect(!covered(p), "\(p)")
        }
        for mask in masks { #expect(IntRect(origin: .zero, size: WindowKind.main.size).contains(mask)) }
        #expect(MuseumScreenshot.masks(.eq).isEmpty)
        // Masked share of Main is small (under 10%), so the metric still covers the window.
        let maskedPixels = masks.reduce(0) { $0 + $1.width * $1.height }
        #expect(maskedPixels < 275 * 116 / 10)
    }

    @Test func windowsStackInTheScreenshot() {
        #expect(MuseumScreenshot.frame(.main) == IntRect(0, 0, 275, 116))
        #expect(MuseumScreenshot.frame(.eq) == IntRect(0, 116, 275, 116))
        #expect(MuseumScreenshot.frame(.playlist).maxY == MuseumScreenshot.size.height)
    }
}

@Suite struct GoldenCompareTests {
    static func pair() -> (Bitmap, Bitmap) {
        (Bitmap(width: 10, height: 4, fill: RGBA(10, 20, 30)), Bitmap(width: 10, height: 4, fill: RGBA(10, 20, 30)))
    }

    @Test func identicalFramesHaveNoDifferences() {
        let (a, b) = Self.pair()
        let (diff, map) = GoldenCompare.compare(a, b, masks: [])
        #expect(diff == GoldenDiff(compared: 40, differing: 0, opacityMismatches: 0, maxDelta: 0))
        #expect(!map.contains(true))
        #expect(diff.share == 0)
    }

    @Test func maskedPixelsAreNotCompared() {
        var (a, b) = Self.pair()
        b[2, 1] = RGBA(200, 0, 0)
        b[9, 3] = RGBA(0, 200, 0)
        let (diff, map) = GoldenCompare.compare(a, b, masks: [IntRect(1, 0, 3, 4)])
        #expect(diff.compared == 40 - 12)
        #expect(diff.differing == 1 && map[3 * 10 + 9] && !map[1 * 10 + 2])
        #expect(diff.maxDelta == 180)   // (10,20,30) vs (0,200,0)
        a[9, 3] = RGBA(0, 200, 0)
        #expect(GoldenCompare.compare(a, b, masks: [IntRect(1, 0, 3, 4)]).diff.differing == 0)
    }

    @Test func toleranceAppliesPerChannel() {
        var (a, b) = Self.pair()
        b[0, 0] = RGBA(12, 20, 30)
        b[1, 0] = RGBA(10, 23, 30)
        #expect(GoldenCompare.compare(a, b, masks: [], tolerance: 0).diff.differing == 2)
        #expect(GoldenCompare.compare(a, b, masks: [], tolerance: 2).diff.differing == 1)
        #expect(GoldenCompare.compare(a, b, masks: [], tolerance: 3).diff.differing == 0)
        a[5, 2] = RGBA(0, 0, 0, 0)
        #expect(GoldenCompare.compare(a, b, masks: [], tolerance: 3).diff.differing == 1)
    }

    @Test func transparencyIsComparedByOpacityOnly() {
        var (a, b) = Self.pair()
        a[0, 0] = RGBA(1, 2, 3, 0)
        b[0, 0] = RGBA(200, 100, 50, 0)   // both transparent: colour irrelevant
        a[1, 0] = .clear                  // shaped away in the render, opaque in the screenshot
        b[2, 0] = RGBA(10, 20, 30, 100)   // anti-aliased edge in the screenshot reads as transparent
        a[3, 0] = RGBA(10, 20, 30, 200)   // and from 128 up as opaque
        let (diff, map) = GoldenCompare.compare(a, b, masks: [])
        #expect(diff.differing == 2 && diff.opacityMismatches == 2)
        #expect(map[1] && map[2] && !map[0] && !map[3])
    }

    @Test func differencesAreAttributedToControls() {
        var map = [Bool](repeating: false, count: 275 * 116)
        map[90 * 275 + 50] = true    // play button (39,88 23x18)
        map[75 * 275 + 100] = true   // position bar
        map[60 * 275 + 2] = true     // left edge: window background
        let counts = GoldenCompare.attribute(map, window: .main)
        #expect(counts == ["play": 1, "position": 1, "background": 1])
    }

    @Test func screenshotDecoderKeepsAlpha() throws {
        var bitmap = Bitmap(width: 4, height: 2, fill: RGBA(0x12, 0x34, 0x56))
        bitmap[0, 0] = .clear
        bitmap[3, 1] = RGBA(255, 0, 255)
        let decoded = try ScreenshotDecoder.decode(try #require(bitmap.pngData()))
        #expect(decoded.size == bitmap.size)
        #expect(decoded[0, 0].a == 0)
        #expect(decoded[1, 0] == RGBA(0x12, 0x34, 0x56) && decoded[3, 1] == RGBA(255, 0, 255))
    }

    @Test func screenshotStateRendersWithoutFallbackForACompleteSkin() throws {
        // AndAmp Dark has every core sheet: neither window may draw from the fallback, or it would be unscorable.
        let skin = try #require(SkinLoader.load(url: Repo.url("Fixtures/skins/AndAmp-Dark.wsz")).skin)
        for window in MuseumScreenshot.windows {
            let result = WindowComposer.render(window, state: MuseumScreenshot.state(window), skin: skin)
            #expect(result.metadata.fallbackSheets.isEmpty, "\(window): \(result.metadata.fallbackSheets)")
            #expect(result.bitmap.size == MuseumScreenshot.frame(window).size)
        }
    }
}

// MARK: - Corpus run (SKINKIT_GOLDEN=1; scripts/golden-compare.sh)

struct GoldenManifest: Decodable {
    struct Entry: Decodable {
        var md5: String
        var filename: String
        var wsz: String
        var png: String
    }

    var museumCount: Int?
    var skins: [Entry]
}

struct GoldenSkinReport: Codable {
    var md5: String
    var filename: String
    /// "scored", "rejected" (archive refused), "incomplete" (a window drew fallback sheets), "missing" (not
    /// downloaded), "badScreenshot" (not 275x348).
    var status: String
    var note: String?
    var main: GoldenDiff?
    var eq: GoldenDiff?
    /// The same comparison allowing 2/255 per channel (colour management noise check).
    var mainTolerant: GoldenDiff?
    var eqTolerant: GoldenDiff?
    var mainControls: [String: Int]?
    var eqControls: [String: Int]?
    var fallbackSheets: [String]?
    var regions: [String]?
    /// SkinLoader's own timing (this harness runs a debug build; `sudamp-dev skin-bench` is the release figure).
    var loadMillis: Double?

    var passes: Bool { (main?.share ?? 1) <= GoldenRun.threshold && (eq?.share ?? 1) <= GoldenRun.threshold }
}

enum GoldenRun {
    static let threshold = 0.005

    static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["SKINKIT_GOLDEN_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/sudamp-dev/golden")
    }

    static var enabled: Bool { ProcessInfo.processInfo.environment["SKINKIT_GOLDEN"] == "1" }

    /// A strip of reference | render | difference (red where differing, masked areas dimmed), Main over EQ, at 2x.
    static func strip(reference: Bitmap, renders: [WindowKind: Bitmap], maps: [WindowKind: [Bool]]) -> Bitmap {
        var out = Bitmap(width: 275 * 3 + 8, height: 232, fill: RGBA(40, 40, 40))
        for window in MuseumScreenshot.windows {
            let frame = MuseumScreenshot.frame(window)
            let ref = reference.cropped(frame)
            var refOpaque = Bitmap(width: 275, height: 116, fill: RGBA(255, 0, 255))
            refOpaque.draw(ref, at: .zero, mode: .over)
            out.draw(refOpaque, at: IntPoint(0, frame.y))
            if let render = renders[window] {
                var ours = Bitmap(width: 275, height: 116, fill: RGBA(255, 0, 255))
                ours.draw(render, at: .zero, mode: .over)
                out.draw(ours, at: IntPoint(279, frame.y))
                var diff = Bitmap(width: 275, height: 116)
                for y in 0..<116 {
                    for x in 0..<275 {
                        let p = refOpaque[x, y]
                        let grey = UInt8((Int(p.r) + Int(p.g) + Int(p.b)) / 6)
                        diff[x, y] = maps[window]?[y * 275 + x] == true ? RGBA(255, 0, 0) : RGBA(grey, grey, grey)
                    }
                }
                for mask in MuseumScreenshot.masks(window) { diff.fill(mask, RGBA(0, 0, 90)) }
                out.draw(diff, at: IntPoint(558, frame.y))
            }
        }
        return scaled(out, 2)
    }

    static func scaled(_ bitmap: Bitmap, _ factor: Int) -> Bitmap {
        var out = Bitmap(width: bitmap.width * factor, height: bitmap.height * factor)
        for y in 0..<out.height { for x in 0..<out.width { out[x, y] = bitmap[x / factor, y / factor] } }
        return out
    }

    /// Connected areas (4-neighbour) of pixels that differ in at least `minimum` skins: the systematic differences.
    static func hotSpots(_ counts: [Int], window: WindowKind, minimum: Int) -> [(rect: IntRect, pixels: Int, peak: Int, control: String)] {
        let size = window.size
        var seen = [Bool](repeating: false, count: counts.count)
        var spots: [(IntRect, Int, Int, String)] = []
        for start in 0..<counts.count where !seen[start] && counts[start] >= minimum {
            var stack = [start], pixels = 0, peak = 0
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            var controls: [String: Int] = [:]
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % size.width, y = i / size.width
                pixels += 1
                peak = max(peak, counts[i])
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                controls[Layout.hitTest(window, IntPoint(x, y))?.rawValue ?? "background", default: 0] += 1
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < size.width, ny < size.height else { continue }
                    let j = ny * size.width + nx
                    if !seen[j] && counts[j] >= minimum { seen[j] = true; stack.append(j) }
                }
            }
            let control = controls.max { $0.value < $1.value }?.key ?? "background"
            spots.append((IntRect(minX, minY, maxX - minX + 1, maxY - minY + 1), pixels, peak, control))
        }
        return spots.sorted { $0.1 > $1.1 }.map { (rect: $0.0, pixels: $0.1, peak: $0.2, control: $0.3) }
    }

    /// How often each pixel differs across scored skins, as a heat map (black = never, white = every skin).
    static func heatMap(_ counts: [Int], size: IntSize, skins: Int) -> Bitmap {
        var out = Bitmap(size)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let v = UInt8(min(255, counts[y * size.width + x] * 255 / max(1, skins)))
                out[x, y] = RGBA(v, v, v)
            }
        }
        return scaled(out, 3)
    }
}

@Suite(.serialized) struct MuseumGoldenHarness {
    @Test(.enabled(if: GoldenRun.enabled, "set SKINKIT_GOLDEN=1 (scripts/golden-compare.sh) to score the museum corpus"))
    func scoreCorpus() throws {
        let dir = GoldenRun.directory
        let manifest = try JSONDecoder().decode(GoldenManifest.self, from: Data(contentsOf: dir.appending(path: "manifest.json")))
        let out = dir.appending(path: "report")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out.appending(path: "strips"), withIntermediateDirectories: true)

        var reports: [GoldenSkinReport] = []
        var heat: [WindowKind: [Int]] = [.main: [Int](repeating: 0, count: 275 * 116), .eq: [Int](repeating: 0, count: 275 * 116)]
        let started = Date()
        for entry in manifest.skins {
            var report = GoldenSkinReport(md5: entry.md5, filename: entry.filename, status: "scored")
            let wsz = dir.appending(path: entry.wsz), png = dir.appending(path: entry.png)
            guard let pngData = try? Data(contentsOf: png), FileManager.default.fileExists(atPath: wsz.path) else {
                report.status = "missing"
                reports.append(report)
                continue
            }
            let loaded = SkinLoader.load(url: wsz)
            guard let skin = loaded.skin else {
                report.status = "rejected"
                report.note = loaded.rejection.map { "\($0)" }
                reports.append(report)
                continue
            }
            report.regions = skin.report.regionSections
            report.loadMillis = skin.report.loadMillis
            guard let reference = try? ScreenshotDecoder.decode(pngData), reference.size == MuseumScreenshot.size else {
                report.status = "badScreenshot"
                reports.append(report)
                continue
            }
            var renders: [WindowKind: Bitmap] = [:], maps: [WindowKind: [Bool]] = [:]
            var fallback = Set<String>()
            for window in MuseumScreenshot.windows {
                let result = WindowComposer.render(window, state: MuseumScreenshot.state(window), skin: skin, hash: false)
                fallback.formUnion(result.metadata.fallbackSheets)
                let crop = reference.cropped(MuseumScreenshot.frame(window))
                let masks = MuseumScreenshot.masks(window)
                let exact = GoldenCompare.compare(result.bitmap, crop, masks: masks)
                let tolerant = GoldenCompare.compare(result.bitmap, crop, masks: masks, tolerance: 2)
                renders[window] = result.bitmap
                maps[window] = exact.map
                if window == .main {
                    report.main = exact.diff
                    report.mainTolerant = tolerant.diff
                    report.mainControls = GoldenCompare.attribute(exact.map, window: window)
                } else {
                    report.eq = exact.diff
                    report.eqTolerant = tolerant.diff
                    report.eqControls = GoldenCompare.attribute(exact.map, window: window)
                }
            }
            if !fallback.isEmpty {
                report.status = "incomplete"
                report.fallbackSheets = fallback.sorted()
            } else {
                for window in MuseumScreenshot.windows {
                    for (i, differs) in (maps[window] ?? []).enumerated() where differs { heat[window]?[i] += 1 }
                }
            }
            if let strip = GoldenRun.strip(reference: reference, renders: renders, maps: maps).pngData() {
                let worst = String(format: "%05.2f", max(report.main?.share ?? 0, report.eq?.share ?? 0) * 100)
                let name = "\(worst)-\(entry.md5).png"
                try strip.write(to: out.appending(path: "strips/\(name)"))
            }
            reports.append(report)
        }

        let scored = reports.filter { $0.status == "scored" }
        let passing = scored.filter(\.passes)
        let mainPass = scored.filter { ($0.main?.share ?? 1) <= GoldenRun.threshold }
        let eqPass = scored.filter { ($0.eq?.share ?? 1) <= GoldenRun.threshold }
        let exactBoth = scored.filter { $0.main?.differing == 0 && $0.eq?.differing == 0 }
        let tolerantPass = scored.filter { ($0.mainTolerant?.share ?? 1) <= GoldenRun.threshold && ($0.eqTolerant?.share ?? 1) <= GoldenRun.threshold }
        func pct(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.1f%%", Double(n) * 100 / Double(d)) }
        func percent(_ share: Double?) -> String { String(format: "%.2f%%", (share ?? 0) * 100) }
        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }

        let loads = reports.compactMap(\.loadMillis).sorted()
        let loadStats = loads.isEmpty ? "n/a" : String(format: "%.1f / %.1f / %.1f ms", loads[loads.count / 2],
                                                         loads[min(loads.count - 1, Int(Double(loads.count) * 0.95))], loads.last ?? 0)

        // Systematic differences: controls that differ in many scored skins.
        var controlSkins: [String: Int] = [:], controlPixels: [String: Int] = [:]
        for r in scored {
            for (prefix, controls) in [("main", r.mainControls ?? [:]), ("eq", r.eqControls ?? [:])] {
                for (control, n) in controls where n > 0 {
                    controlSkins["\(prefix).\(control)", default: 0] += 1
                    controlPixels["\(prefix).\(control)", default: 0] += n
                }
            }
        }
        let ranked = controlSkins.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }

        var summary = """
        # Museum golden metric

        Corpus: \(dir.path) (\(manifest.skins.count) skins in the manifest; museum size \(manifest.museumCount.map(String.init) ?? "?")).

        | Measure | Value |
        |---|---|
        | Skins scored (complete, loaded, 275x348 screenshot) | \(scored.count) |
        | Not scored: rejected / incomplete after load / missing / bad screenshot | \(reports.filter { $0.status == "rejected" }.count) / \(reports.filter { $0.status == "incomplete" }.count) / \(reports.filter { $0.status == "missing" }.count) / \(reports.filter { $0.status == "badScreenshot" }.count) |
        | **Main and EQ both within 0.5% differing pixels** | **\(passing.count) of \(scored.count) (\(pct(passing.count, scored.count)))** |
        | Main within 0.5% | \(mainPass.count) (\(pct(mainPass.count, scored.count))) |
        | EQ within 0.5% | \(eqPass.count) (\(pct(eqPass.count, scored.count))) |
        | Both within 0.5% allowing 2/255 per channel | \(tolerantPass.count) (\(pct(tolerantPass.count, scored.count))) |
        | Both pixel-identical outside the masks | \(exactBoth.count) |
        | Median differing share, Main / EQ | \(String(format: "%.2f%% / %.2f%%", median(scored.compactMap { $0.main?.share }) * 100, median(scored.compactMap { $0.eq?.share }) * 100)) |
        | Skin load p50 / p95 / max (debug build, SkinLoader timing) | \(loadStats) |
        | Run time | \(String(format: "%.1f s", Date().timeIntervalSince(started))) |

        ## Where differences concentrate (skins with any differing pixel on the control)

        | Window.control | Skins | Pixels (all skins) |
        |---|---|---|

        """
        for (control, skins) in ranked.prefix(25) {
            summary += "| \(control) | \(skins) (\(pct(skins, scored.count))) | \(controlPixels[control] ?? 0) |\n"
        }
        summary += "\n## Hot spots (pixels differing in at least 25% of scored skins)\n\n| Window | Area | Pixels | Peak skins | Mostly on |\n|---|---|---|---|---|\n"
        for window in MuseumScreenshot.windows {
            for spot in GoldenRun.hotSpots(heat[window] ?? [], window: window, minimum: max(1, scored.count / 4)) {
                summary += "| \(window.rawValue) | \(spot.rect) | \(spot.pixels) | \(spot.peak) | \(spot.control) |\n"
            }
        }
        summary += "\n## Skins over the threshold (worst first)\n\n| Skin | Main | EQ | Opacity mismatches (Main/EQ) | Top controls |\n|---|---|---|---|---|\n"
        for r in scored.filter({ !$0.passes }).sorted(by: { max($0.main?.share ?? 0, $0.eq?.share ?? 0) > max($1.main?.share ?? 0, $1.eq?.share ?? 0) }) {
            let top = ((r.mainControls ?? [:]).map { ("main.\($0.key)", $0.value) } + (r.eqControls ?? [:]).map { ("eq.\($0.key)", $0.value) })
                .sorted { $0.1 > $1.1 }.prefix(3).map { "\($0.0) \($0.1)" }.joined(separator: ", ")
            summary += "| `\(r.md5.prefix(8))` \(r.filename) | \(percent(r.main?.share)) | \(percent(r.eq?.share)) | "
                + "\(r.main?.opacityMismatches ?? 0) / \(r.eq?.opacityMismatches ?? 0) | \(top) |\n"
        }
        let notScored = reports.filter { $0.status != "scored" }
        if !notScored.isEmpty {
            summary += "\n## Not scored\n\n"
            for r in notScored { summary += "- `\(r.md5.prefix(8))` \(r.filename): \(r.status)\(r.note.map { " (\($0))" } ?? "")\(r.fallbackSheets.map { " fallback: \($0.joined(separator: ", "))" } ?? "")\n" }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: out.appending(path: "report.json"))
        try Data(summary.utf8).write(to: out.appending(path: "summary.md"))
        for window in MuseumScreenshot.windows {
            if let png = GoldenRun.heatMap(heat[window] ?? [], size: window.size, skins: scored.count).pngData() {
                try png.write(to: out.appending(path: "heat-\(window.rawValue).png"))
            }
        }
        print(summary)
        #expect(scored.count > 0, "no scorable skins in \(dir.path); run scripts/golden-fetch.sh first")
    }
}
