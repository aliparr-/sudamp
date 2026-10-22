// SPDX-License-Identifier: GPL-3.0-or-later
// A loaded classic skin: decoded sheets, parsed text files and the fallback rules that fill the gaps
// (DESIGN §8.2). A missing or undecodable sheet comes from the fallback skin (sudamp Dark), as Winamp fell back
// to its base skin; balance falls back to the skin's own volume sprites and the EQ maximise button to the
// eqmain title bar (Webamp components/Skin.tsx FALLBACKS @ 7734cd3); digits prefer nums_ex.bmp over numbers.bmp.
//
// Notices for the sources named above:
//
// Webamp — The MIT License (MIT), Copyright (c) [2015] [Jordan Eldredge]
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

/// Where a sheet or text file used by a skin came from.
public enum SkinOrigin: String, Codable, Sendable {
    case skin, fallback, missing
}

/// A sprite resolved to the bitmap that holds it.
public struct ResolvedSprite: Sendable {
    public let sheet: Bitmap
    /// The sprite's rect in `sheet`; it may run past the sheet's edge, where nothing is drawn.
    public let rect: IntRect
    public let origin: SkinOrigin
}

public struct Skin: Sendable {
    public let name: String
    /// Sheets decoded from this skin, by lower-case basename ("main", "nums_ex", "genex", …).
    public let sheets: [String: Bitmap]
    /// The fallback skin's sheets (empty for the fallback itself).
    public let fallbackSheets: [String: Bitmap]
    public let viscolors: [RGBA]
    public let playlistStyle: PlaylistStyle
    /// Parsed region.txt sections; empty when the skin has none (the fallback's regions never apply).
    public let regions: [String: [[RegionPoint]]]
    public let report: SkinLoadReport
    /// text.bmp's colours, worked out once (see `textColorsOf`): the marquee asks on every scroll step.
    public let textColors: (foreground: RGBA, background: RGBA)

    init(name: String, sheets: [String: Bitmap], fallbackSheets: [String: Bitmap], viscolors: [RGBA],
         playlistStyle: PlaylistStyle, regions: [String: [[RegionPoint]]], report: SkinLoadReport) {
        self.name = name
        self.sheets = sheets
        self.fallbackSheets = fallbackSheets
        self.viscolors = viscolors
        self.playlistStyle = playlistStyle
        self.regions = regions
        self.report = report
        // A text.bmp too narrow to sample would give a transparent background (the system-font marquee field
        // would be see-through); then the fallback skin's colours are used.
        textColors = sheets["text"].flatMap(Self.textColorsOf) ?? fallbackSheets["text"].flatMap(Self.textColorsOf)
            ?? (.white, .black)
    }

    /// The bitmap used for a sheet, and whether it is the skin's own.
    public func sheet(_ base: String) -> (bitmap: Bitmap, origin: SkinOrigin)? {
        if let own = sheets[base] { return (own, .skin) }
        if let fallback = fallbackSheets[base] { return (fallback, .fallback) }
        return nil
    }

    public func sheet(_ sheet: SpriteSheet) -> (bitmap: Bitmap, origin: SkinOrigin)? {
        self.sheet(sheet.fileBase)
    }

    /// Resolves a sprite with Webamp's sprite-level fallbacks applied before falling back per sheet.
    public func resolve(_ sprite: Sprite) -> ResolvedSprite? {
        if let substitute = Self.ownSheetSubstitutes[sprite], sheets[sprite.source.sheet.fileBase] == nil,
           sheets[substitute.source.sheet.fileBase] != nil {
            return resolve(direct: substitute)
        }
        return resolve(direct: sprite)
    }

    private func resolve(direct sprite: Sprite) -> ResolvedSprite? {
        guard let (bitmap, origin) = sheet(sprite.source.sheet) else { return nil }
        return ResolvedSprite(sheet: bitmap, rect: sprite.source.rect, origin: origin)
    }

    /// When the skin lacks a sprite's sheet but has the substitute's, Webamp draws the substitute from the
    /// skin itself rather than from a default skin.
    static let ownSheetSubstitutes: [Sprite: Sprite] = [
        .mainBalanceBackground: .mainVolumeBackground,
        .mainBalanceThumb: .mainVolumeThumb,
        .mainBalanceThumbActive: .mainVolumeThumbSelected,
        .eqMaximizeButtonActive: .eqMaximizeButtonActiveFallback,
    ]

    /// Which digit set the time display uses: the skin's nums_ex, else its numbers, else the fallback's choice.
    public var digitSet: DigitSet {
        if sheets["nums_ex"] != nil { return .numsEx }
        if sheets["numbers"] != nil { return .numbers }
        return fallbackSheets["nums_ex"] != nil ? .numsEx : .numbers
    }

    public enum DigitSet: String, Sendable, Codable {
        case numbers, numsEx
    }

    /// Sprite for digit 0-9 in the active digit set.
    public func digit(_ value: Int) -> Sprite {
        let names: [Sprite] = digitSet == .numsEx
            ? [.digit0Ex, .digit1Ex, .digit2Ex, .digit3Ex, .digit4Ex, .digit5Ex, .digit6Ex, .digit7Ex, .digit8Ex, .digit9Ex]
            : [.digit0, .digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9]
        return names[min(max(value, 0), 9)]
    }

    /// The text.bmp cell for an already-normalised character, if the font has one.
    public func textGlyph(_ character: Character) -> ResolvedSprite? {
        guard let cell = FontLookup.cells[character], let (bitmap, origin) = sheet(.text) else { return nil }
        let rect = IntRect(cell.column * FontLookup.cellWidth, cell.row * FontLookup.cellHeight,
                           FontLookup.cellWidth, FontLookup.cellHeight)
        return ResolvedSprite(sheet: bitmap, rect: rect, origin: origin)
    }

    /// text.bmp's colours, for drawing text the bitmap font cannot show (DESIGN §8.3; Audacious and the research
    /// both take them from text.bmp, not pledit.txt): the background is the space glyph's centre, the foreground
    /// the letter pixel that differs most from it. Nil when the sheet is too small to hold the space glyph.
    static func textColorsOf(_ text: Bitmap) -> (foreground: RGBA, background: RGBA)? {
        let background = text[30 * 5 + 2, 2]
        guard background.a != 0 else { return nil }
        var best = background, bestDistance = -1
        for y in 0..<min(6, text.height) {
            for x in 0..<min(26 * 5, text.width) {
                let p = text[x, y]
                let d = max(abs(Int(p.r) - Int(background.r)), abs(Int(p.g) - Int(background.g)), abs(Int(p.b) - Int(background.b)))
                if d > bestDistance {
                    bestDistance = d
                    best = p
                }
            }
        }
        return (best, background)
    }

    /// The window's region.txt alpha mask (255 inside), or nil when the skin does not shape this window. SkinUI
    /// uses it for click-through and the shadow; the composer applies it to frames.
    public func regionMask(_ window: WindowKind) -> [UInt8]? {
        guard let section = window.regionSection, let polygons = regions[section] else { return nil }
        return RegionRasterizer.mask(polygons, size: window.size)
    }

    /// The 19 EQ graph colours, top (+12 dB) to bottom: the 1x19 EQ_GRAPH_LINE_COLORS strip in eqmain.bmp.
    public var eqGraphColors: [RGBA] {
        guard let resolved = resolve(.eqGraphLineColors) else { return [RGBA](repeating: .white, count: 19) }
        return (0..<19).map { resolved.sheet[resolved.rect.x, resolved.rect.y + $0] }
    }
}
