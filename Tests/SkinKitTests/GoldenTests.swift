// SPDX-License-Identifier: GPL-3.0-or-later
// Render goldens (PLAN M4): the SHA-256 of the decoded RGBA8 frame for each state fixture, per skin, committed in
// Fixtures/states/goldens.json. PNG bytes are not compared (they vary across macOS versions). After an intended
// rendering change, run the tests once with SKINKIT_UPDATE_GOLDENS=1 to rewrite the file, and review the diff.
import Foundation
import Testing
@testable import SkinKit

@Suite(.serialized) struct GoldenRenderTests {
    static let goldensPath = "Fixtures/states/goldens.json"
    /// Skins and the states rendered with each: sudamp Dark gets every state, AndAmp Dark one per window.
    static let plan: [(skin: String, file: String?, states: [String]?)] = [
        ("sudamp-dark", nil, nil),
        ("andamp-dark", "Fixtures/skins/AndAmp-Dark.wsz", ["02-main-playing", "08-shade-playing", "09-eq-curve", "11-playlist-rows"]),
    ]

    static func stateNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: Repo.url("Fixtures/states").path)
            .filter { $0.hasSuffix(".json") && $0 != "goldens.json" }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    static func render(_ state: String, skin: Skin) throws -> RenderResult {
        let decoded = try JSONDecoder().decode(WindowState.self, from: Repo.data("Fixtures/states/\(state).json"))
        return WindowComposer.render(decoded.window ?? .main, state: decoded, skin: skin)
    }

    static func actual() throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for entry in plan {
            let skin = try entry.file.map { try #require(SkinLoader.load(url: Repo.url($0)).skin) } ?? SudampDark.skin
            for state in try entry.states ?? stateNames() {
                result[entry.skin, default: [:]][state] = try render(state, skin: skin).metadata.sha256
            }
        }
        return result
    }

    @Test func rgbaHashesMatchGoldens() throws {
        let actual = try Self.actual()
        if ProcessInfo.processInfo.environment["SKINKIT_UPDATE_GOLDENS"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(actual).write(to: Repo.url(Self.goldensPath))
        }
        let expected = try JSONDecoder().decode([String: [String: String]].self, from: Repo.data(Self.goldensPath))
        #expect(expected["sudamp-dark"]?.count ?? 0 >= 12)
        #expect(expected["andamp-dark"]?.count == 4)
        for (skin, states) in expected {
            for (state, hash) in states {
                #expect(actual[skin]?[state] == hash, "\(skin)/\(state): got \(actual[skin]?[state] ?? "nil")")
            }
        }
        #expect(Set(actual.keys) == Set(expected.keys))
        for (skin, states) in actual { #expect(Set(states.keys) == Set(expected[skin]?.keys ?? [:].keys), "\(skin) state list") }
    }

    @Test func cjkTitleSwitchesToTheSystemFont() throws {
        let system = try Self.render("06-main-cjk-system", skin: SudampDark.skin).metadata.marquee
        #expect(system?.fallback == "system")
        let skinFont = try Self.render("07-main-cjk-skin-font", skin: SudampDark.skin).metadata.marquee
        #expect(skinFont?.fallback == "transliterated")
        #expect(skinFont?.text.hasPrefix("[lofi] dong jing") == true, "\(skinFont?.text ?? "")")
        #expect(try Self.render("02-main-playing", skin: SudampDark.skin).metadata.marquee?.fallback == "none")
    }

    @Test func renderingIsDeterministic() throws {
        for state in try Self.stateNames() {
            #expect(try Self.render(state, skin: SudampDark.skin).bitmap == Self.render(state, skin: SudampDark.skin).bitmap)
        }
    }
}

@Suite struct FuzzTests {
    /// In-process smoke run of the fuzzer over the committed skins; `sudamp-dev skin-fuzz` runs the 2000-case gate.
    @Test func mutatedSkinsNeverCrashTheLoader() async throws {
        var bases = [SudampDark.archive()]
        for name in ["AndAmp-Dark.wsz", "AndAmp-Light.wsz"] { bases.append(try Repo.data("Fixtures/skins/" + name)) }
        let (loaded, rejected) = try await offPool { [bases] in
            var rng = SeededRandomForTests(seed: 42)
            var loaded = 0, rejected = 0
            var state = WindowState()
            state.playback = .playing
            state.title = "FUZZ"
            for i in 0..<240 {
                let mutation = SkinFuzzer.Mutation.allCases[i % SkinFuzzer.Mutation.allCases.count]
                let data = SkinFuzzer.mutate(bases[i % bases.count], mutation, using: &rng)
                if let skin = SkinLoader.load(data: data).skin {
                    loaded += 1
                    for window in WindowKind.allCases { _ = WindowComposer.render(window, state: state, skin: skin) }
                } else {
                    rejected += 1
                }
            }
            return (loaded, rejected)
        }
        #expect(loaded + rejected == 240)
        #expect(loaded > 0 && rejected > 0)
    }

    @Test func mutationsAreReproducible() async throws {
        let differing = try await offPool {
            var a = SeededRandomForTests(seed: 7), b = SeededRandomForTests(seed: 7)
            let base = SudampDark.archive()
            return SkinFuzzer.Mutation.allCases.filter {
                SkinFuzzer.mutate(base, $0, using: &a) != SkinFuzzer.mutate(base, $0, using: &b)
            }.map { "\($0)" }
        }
        #expect(differing.isEmpty, "\(differing)")
    }
}

/// SplitMix64, as Core's SeededRandom (SkinKitTests only depends on SkinKit).
struct SeededRandomForTests: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct ComposerLayerTests {
    @Test func baseplusLayersEqualsTheFullFrame() throws {
        var state = try JSONDecoder().decode(WindowState.self, from: Repo.data("Fixtures/states/02-main-playing.json"))
        state.marqueeStep = 4
        state.title = String(repeating: "LONG TITLE ", count: 5)
        let skin = SudampDark.skin
        let full = WindowComposer.render(.main, state: state, skin: skin).bitmap
        var layered = state
        layered.options.drawDynamicLayers = false
        var base = WindowComposer.render(.main, state: layered, skin: skin).bitmap
        #expect(base != full)
        let marquee = WindowComposer.marqueeLayer(state: state, skin: skin, base: base)
        let vis = WindowComposer.visualizerLayer(try #require(state.visualizer), skin: skin, shade: false)
        base.draw(marquee.bitmap, at: MainLayout.marqueeText.origin)
        base.draw(vis, at: MainLayout.visualizer.origin)
        #expect(base == full)
        #expect(marquee.metadata.offset == 20)
    }

    @Test func regionMaskMatchesTheRenderedAlpha() throws {
        let skin = try #require(SkinLoader.load(url: Repo.url("Fixtures/skins/AndAmp-Dark.wsz")).skin)
        let mask = try #require(skin.regionMask(.main))
        let frame = WindowComposer.render(.main, state: WindowState(), skin: skin).bitmap
        for y in [0, 1, 57, 115] {
            for x in [0, 3, 137, 274] { #expect(mask[y * 275 + x] == frame[x, y].a) }
        }
        #expect(skin.regionMask(.playlist) == nil)
        #expect(SudampDark.skin.regionMask(.main) == nil)
        #expect(RegionRasterizer.contains(mask, size: WindowKind.main.size, IntPoint(137, 58)))
        #expect(!RegionRasterizer.contains(mask, size: WindowKind.main.size, IntPoint(0, 0)))
    }
}

@Suite struct BitmapTests {
    @Test func drawClipsToBothBitmaps() {
        var source = Bitmap(width: 4, height: 4, fill: .white)
        source[3, 3] = RGBA(9, 9, 9)
        var target = Bitmap(width: 3, height: 3, fill: .black)
        target.draw(source, from: IntRect(2, 2, 4, 4), at: IntPoint(-1, 0))
        // Source (3,2)->(0,0), (3,3)->(0,1); the rest of the rect is off the source or the target.
        #expect(target[0, 0] == .white)
        #expect(target[0, 1] == RGBA(9, 9, 9))
        #expect(target[1, 0] == .black && target[0, 2] == .black)
        #expect(source.cropped(IntRect(3, 3, 2, 2))[1, 1] == .clear)
    }

    @Test func overBlendsStraightAlpha() {
        var target = Bitmap(width: 1, height: 1, fill: RGBA(0, 0, 255))
        target.draw(Bitmap(width: 1, height: 1, fill: RGBA(255, 0, 0, 128)), at: .zero, mode: .over)
        #expect(target[0, 0] == RGBA(128, 0, 127, 255))
        var clear = Bitmap(width: 1, height: 1)
        clear.draw(Bitmap(width: 1, height: 1, fill: RGBA(255, 0, 0, 128)), at: .zero, mode: .over)
        #expect(clear[0, 0] == RGBA(255, 0, 0, 128))
    }

    @Test func bmpRoundTripsThroughImageIO() throws {
        var bitmap = Bitmap(width: 7, height: 3, fill: RGBA(hex: 0x0D9488))
        bitmap[6, 2] = RGBA(hex: 0xFFFFFF)
        bitmap[0, 0] = RGBA(hex: 0x010203)
        #expect(try SheetDecoder.decode(BMPWriter.encode(bitmap)) == bitmap)
    }

    @Test func hashIsOverRawRGBA() {
        let bitmap = Bitmap(width: 1, height: 1, fill: RGBA(0, 0, 0, 0))
        // SHA-256 of four zero bytes.
        #expect(bitmap.sha256 == "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119")
    }
}

@Suite struct HostileTextFuzzTests {
    @Test func everyHostileTextLoadsAndRenders() throws {
        for text in SkinFuzzer.hostileTexts {
            let data = ZipWriter.archive([
                ZipWriter.Entry(path: "main.bmp", data: solidBMP(width: 275, height: 116, .black)),
                ZipWriter.Entry(path: "region.txt", data: Data(text.utf8)),
                ZipWriter.Entry(path: "viscolor.txt", data: Data(text.utf8)),
                ZipWriter.Entry(path: "pledit.txt", data: Data(text.utf8)),
            ])
            let skin = try #require(SkinLoader.load(data: data).skin)
            for window in WindowKind.allCases { _ = WindowComposer.render(window, state: WindowState(), skin: skin) }
        }
    }
}
