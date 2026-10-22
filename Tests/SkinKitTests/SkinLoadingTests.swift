// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SkinKit

private func archive(_ files: [(String, Data)]) -> Data {
    ZipWriter.archive(files.map { ZipWriter.Entry(path: $0.0, data: $0.1, method: .deflate) })
}

private func load(_ files: [(String, Data)]) throws -> Skin {
    let result = SkinLoader.load(data: archive(files), name: "test")
    return try #require(result.skin, "rejected: \(String(describing: result.rejection))")
}

@Suite struct SkinLoadingTests {
    let red = RGBA(hex: 0xFF0000), green = RGBA(hex: 0x00FF00), blue = RGBA(hex: 0x0000FF)

    @Test func missingSheetsComeFromSudampDark() throws {
        let skin = try load([("main.bmp", solidBMP(width: 275, height: 116, red))])
        #expect(skin.sheet(.main)?.origin == .skin)
        #expect(skin.sheet(.cbuttons)?.origin == .fallback)
        #expect(skin.report.sheets.first { $0.name == "main" }?.origin == .skin)
        #expect(skin.report.fallbackSheets.contains("titlebar"))
        #expect(skin.report.viscolor == .fallback)
        #expect(skin.viscolors == SudampDark.skin.viscolors)
        let frame = WindowComposer.render(.main, state: WindowState(), skin: skin)
        #expect(frame.bitmap[190, 45] == red)
        #expect(frame.metadata.fallbackSheets.contains("titlebar"))
    }

    @Test func lastImageWinsFirstPleditWins() throws {
        let skin = try load([
            ("Skin/MAIN.BMP", solidBMP(width: 275, height: 116, red)),
            ("pledit.txt", Data("[Text]\nNormal=#010203".utf8)),
            ("other/main.bmp", solidBMP(width: 275, height: 116, green)),
            ("other/PLEDIT.TXT", Data("[Text]\nNormal=#040506".utf8)),
        ])
        #expect(skin.sheets["main"]?[0, 0] == green)
        #expect(skin.playlistStyle.normal == RGBA(1, 2, 3))
        #expect(skin.report.pledit == .skin)
    }

    @Test func nestedFoldersMixedCaseAndPNG() throws {
        let png = try #require(Bitmap(width: 275, height: 116, fill: blue).pngData())
        let skin = try load([("My Skin\\Sub\\MaIn.PnG", png), ("__MACOSX/._main.bmp", Data([1, 2, 3])), ("readme.exe", Data([0x4D, 0x5A]))])
        #expect(skin.sheets["main"]?[10, 10] == blue)
        #expect(skin.report.ignoredEntries == 2)
    }

    @Test func balanceFallsBackToTheSkinsOwnVolume() throws {
        var volume = Bitmap(width: 68, height: 433, fill: green)
        volume.fill(IntRect(0, 0, 68, 15), red)  // frame 0 red
        let skin = try load([("volume.bmp", BMPWriter.encode(volume))])
        let balance = try #require(skin.resolve(.mainBalanceBackground))
        #expect(balance.origin == .skin)
        #expect(balance.rect == Sprite.mainVolumeBackground.source.rect)
        var state = WindowState()
        state.balance = 0
        let frame = WindowComposer.render(.main, state: state, skin: skin)
        #expect(frame.bitmap[MainLayout.balance.x, MainLayout.balance.y] == red, "balance draws volume's frame 0")
        // Without volume.bmp either, balance comes from the fallback skin.
        let bare = try load([("main.bmp", solidBMP(width: 275, height: 116, red))])
        #expect(bare.resolve(.mainBalanceBackground)?.origin == .fallback)
        #expect(bare.resolve(.mainBalanceBackground)?.rect == Sprite.mainBalanceBackground.source.rect)
    }

    @Test func eqMaximizeFallsBackToTheEqmainTitleBar() throws {
        let skin = try load([("eqmain.bmp", solidBMP(width: 275, height: 315, red))])
        #expect(skin.resolve(.eqMaximizeButtonActive)?.rect == Sprite.eqMaximizeButtonActiveFallback.source.rect)
        #expect(skin.resolve(.eqMaximizeButtonActive)?.origin == .skin)
        let withEx = try load([("eqmain.bmp", solidBMP(width: 275, height: 315, red)), ("eq_ex.bmp", solidBMP(width: 275, height: 56, green))])
        #expect(withEx.resolve(.eqMaximizeButtonActive)?.rect == Sprite.eqMaximizeButtonActive.source.rect)
    }

    @Test func numsExBeatsNumbers() throws {
        let both = try load([("numbers.bmp", solidBMP(width: 99, height: 13, red)), ("nums_ex.bmp", solidBMP(width: 108, height: 13, green))])
        #expect(both.digitSet == .numsEx)
        #expect(both.digit(3) == .digit3Ex)
        let numbers = try load([("numbers.bmp", solidBMP(width: 99, height: 13, red))])
        #expect(numbers.digitSet == .numbers)
        #expect(numbers.digit(3) == .digit3)
        // Remaining-time minus: a 5x1 bar for numbers.bmp at 38,32.
        var state = WindowState()
        state.playback = .playing
        state.duration = 100
        state.timeMode = .remaining
        let frame = WindowComposer.render(.main, state: state, skin: numbers)
        #expect(frame.bitmap[38, 32] == red)
        #expect(frame.bitmap[38, 33] != red)
    }

    @Test func undersizedSheetsShowWhatIsBehind() throws {
        // A 100x30 cbuttons.bmp: next/eject are off the sheet, so the main background shows through.
        let skin = try load([("main.bmp", solidBMP(width: 275, height: 116, red)), ("cbuttons.bmp", solidBMP(width: 100, height: 30, green))])
        let frame = WindowComposer.render(.main, state: WindowState(), skin: skin)
        #expect(frame.bitmap[20, 90] == green)
        #expect(frame.bitmap[140, 92] == red, "eject is past the sheet's edge")
    }

    @Test func badImagesFallBackAndAreReported() throws {
        let skin = try load([
            ("main.bmp", Data("garbage".utf8)),
            ("titlebar.bmp", SkinFuzzer.hugeBMPHeader(width: 40000, height: 40000)),
        ])
        #expect(skin.sheet(.main)?.origin == .fallback)
        #expect(skin.sheet(.titlebar)?.origin == .fallback)
        #expect(skin.report.problems.count == 2)
        #expect(skin.report.sheets.first { $0.name == "titlebar" }?.error != nil)
    }

    @Test func decodedSheetsAreOpaqueSRGB() throws {
        var bitmap = Bitmap(width: 4, height: 4, fill: RGBA(10, 20, 30, 0))
        bitmap[1, 1] = RGBA(200, 100, 50, 255)
        let png = try #require(bitmap.pngData())
        let decoded = try SheetDecoder.decode(png)
        #expect(decoded[1, 1] == RGBA(200, 100, 50))
        #expect(decoded[0, 0] == RGBA(0, 0, 0), "transparent pixels become black, alpha ignored")
        // Over-wide images are refused from the header's size, before pixels are allocated.
        let wide = try #require(Bitmap(width: 2100, height: 2).pngData())
        #expect(throws: SheetDecodeError.tooLarge(width: 2100, height: 2)) { try SheetDecoder.decode(wide) }
        // Headers claiming 40000x40000 over a few bytes of data: ImageIO reports no size, so they are undecodable.
        #expect(throws: SheetDecodeError.undecodable) { try SheetDecoder.decode(hugePNG(40000, 40000)) }
        #expect(throws: SheetDecodeError.self) { try SheetDecoder.decode(SkinFuzzer.hugeBMPHeader(width: 40000, height: 40000)) }
    }

    @Test func textColorsComeFromTextBmp() throws {
        var text = Bitmap(width: 155, height: 18, fill: RGBA(hex: 0x101010))
        text.fill(IntRect(1, 1, 2, 3), RGBA(hex: 0xF0E000))
        let skin = try load([("text.bmp", BMPWriter.encode(text))])
        #expect(skin.textColors.background == RGBA(hex: 0x101010))
        #expect(skin.textColors.foreground == RGBA(hex: 0xF0E000))
    }

    @Test func andAmpDarkLoadsCompletely() throws {
        let result = SkinLoader.load(url: Repo.url("Fixtures/skins/AndAmp-Dark.wsz"))
        let skin = try #require(result.skin)
        #expect(skin.report.fallbackSheets.isEmpty, "\(skin.report.fallbackSheets)")
        #expect(skin.report.problems.isEmpty)
        #expect(Set(skin.regions.keys).isSuperset(of: ["normal", "windowshade", "equalizer", "equalizerws"]))
        let frame = WindowComposer.render(.main, state: WindowState(), skin: skin)
        #expect(frame.metadata.regionApplied)
        #expect(frame.bitmap[0, 0].a == 0, "rounded corner cut by region.txt")
        #expect(frame.bitmap[137, 58].a == 255)
        var noRegion = WindowState()
        noRegion.options.applyRegion = false
        #expect(WindowComposer.render(.main, state: noRegion, skin: skin).bitmap[0, 0].a == 255)
    }
}

@Suite struct SudampDarkTests {
    @Test func generatorIsByteStableAndMatchesTheCommittedSkin() throws {
        let first = SudampDark.archive(), second = SudampDark.archive()
        #expect(first == second)
        #expect(first == (try Repo.data("Fixtures/skins/sudamp-dark.wsz")), "run `skingen` to refresh Fixtures/skins/sudamp-dark.wsz")
    }

    @Test func exportedSkinReloadsAndRendersIdentically() throws {
        let result = SkinLoader.load(data: SudampDark.archive(), name: "sudamp Dark", fallback: nil)
        let reloaded = try #require(result.skin)
        #expect(reloaded.report.problems.isEmpty)
        // sudamp Dark ships nums_ex (preferred over numbers) and no gen.bmp (no gen window in v1).
        #expect(reloaded.report.sheets.filter { $0.origin != .skin }.map(\.name) == ["numbers", "gen"])
        #expect(reloaded.viscolors == SudampDarkTheme.palette.viscolors)
        #expect(reloaded.playlistStyle == SudampDarkTheme.palette.playlistStyle)
        #expect(reloaded.eqGraphColors == SudampDarkTheme.palette.eqGraphColors)
        var state = WindowState()
        state.playback = .playing
        state.title = "round trip"
        for window in WindowKind.allCases {
            #expect(WindowComposer.render(window, state: state, skin: reloaded).bitmap ==
                WindowComposer.render(window, state: state, skin: SudampDark.skin).bitmap, "\(window)")
        }
    }

    @Test func noBorrowedBranding() throws {
        // readme.txt credits Bitamp and states the absence of Nullsoft art; nothing else may name them.
        for (name, data) in SudampDark.files() where name != "readme.txt" {
            let text = String(decoding: data, as: UTF8.self).uppercased()
            for banned in ["BITAMP", "WINAMP", "NULLSOFT", "LLAMA"] {
                #expect(!text.contains(banned), "\(banned) in \(name)")
            }
        }
        #expect(SudampDarkTheme.theme.title == "SUDAMP")
        #expect(SudampDarkTheme.teal == RGBA(hex: 0x0D9488) && SudampDarkTheme.tealBright == RGBA(hex: 0x14B8A6))
    }

    @Test func everyTextCellHasArt() {
        let text = SudampDark.skin.sheets["text"]!
        let background = SudampDark.skin.textColors.background
        for (character, cell) in FontLookup.cells where character != " " {
            let pixels = (0..<6).flatMap { y in (0..<5).map { x in text[cell.column * 5 + x, cell.row * 6 + y] } }
            #expect(pixels.contains { $0 != background }, "no glyph for \(character)")
        }
    }
}

/// A PNG with only an IHDR chunk claiming `width` x `height`, and an empty IDAT.
func hugePNG(_ width: UInt32, _ height: UInt32) -> Data {
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let typed = Array(type.utf8) + body
        let crc = CRC32.checksum(typed)
        let length = UInt32(body.count)
        return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)] + typed
            + [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
    }
    func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    let ihdr = be(width) + be(height) + [8, 2, 0, 0, 0]
    let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr)
        + chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]) + chunk("IEND", [])
    return Data(bytes)
}
