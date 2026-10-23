// SPDX-License-Identifier: GPL-3.0-or-later
// DESIGN §8.4: the modern skin's colour maths, tints and generated artwork palettes.
import Testing
@testable import ModernUI

@Suite struct RGBTests {
    @Test func hexAndHSBRoundTrip() {
        let teal = RGB(hex: 0x0D9488)
        #expect(teal.hex == 0x0D9488 && teal.description == "#0D9488")
        for hex: UInt32 in [0xFF0000, 0x00FF00, 0x0000FF, 0x123456, 0xFEDCBA, 0x808080] {
            let c = RGB(hex: hex)
            let (h, s, b) = c.hsb
            #expect(RGB(hue: h, saturation: s, brightness: b).hex == hex, "\(c)")
        }
    }

    @Test func clampsAndMixes() {
        #expect(RGB(2, -1, .nan) == RGB(1, 0, 0))
        #expect(RGB.black.mixed(with: .white, 0.5) == RGB(0.5, 0.5, 0.5))
        #expect(RGB.black.mixed(with: .white, 3) == .white)
        #expect(RGB(hue: 1.25, saturation: 1, brightness: 1) == RGB(hue: 0.25, saturation: 1, brightness: 1), "hue wraps")
    }

    @Test func contrastFollowsWCAG() {
        #expect(abs(RGB.black.contrast(with: .white) - 21) < 0.01)
        #expect(RGB(hex: 0x777777).contrast(with: .white) > 4.4)
        #expect(RGB.white.contrast(with: .white) == 1)
    }
}

@Suite struct TintTests {
    @Test func tealIsTheDefaultAndEveryTintHasATitle() {
        #expect(ModernTint.default == .teal)
        #expect(ModernTint.allCases.count == 12)
        #expect(ModernTint.allCases.map(\.title).contains("Teal"))
        #expect(ModernAppearance.default == .auto && ModernAppearance.allCases.map(\.title) == ["Automatic", "Light", "Dark"])
    }

    /// The play button's glyph (white or near-black, whichever reads) stays legible on every tint.
    @Test func glyphsOnTheAccentAreLegible() {
        for tint in ModernTint.allCases {
            for dark in [false, true] {
                let accent = dark ? tint.accent.dark : tint.accent.light
                let glyph: RGB = accent.contrast(with: .white) >= 2.2 ? .white : RGB(hex: 0x111114)
                #expect(accent.contrast(with: glyph) >= 2.2, "\(tint) \(dark ? "dark" : "light")")
            }
        }
    }

    /// Accent text (the genre chip, the playing station) reads on light glass and on dark glass.
    @Test func accentTextReadsOnGlass() {
        let lightGlass = RGB(hex: 0xEDEDF0), darkGlass = RGB(hex: 0x26262A)
        for tint in ModernTint.allCases {
            #expect(tint.accent.light.contrast(with: lightGlass) >= 2.2, "\(tint) on light")
            #expect(tint.accent.dark.contrast(with: darkGlass) >= 3, "\(tint) on dark")
        }
    }

    @Test func graphiteGlassIsClearAndTheOthersAreTinted() {
        #expect(ModernTint.graphite.glassStrength(dark: false) == 0 && ModernTint.graphite.glassStrength(dark: true) == 0)
        for tint in ModernTint.allCases where tint != .graphite {
            #expect(tint.glassStrength(dark: false) > 0.1 && tint.glassStrength(dark: true) > 0.1)
            #expect(tint.deep(dark: false) != tint.accent.light, "gradients run somewhere")
        }
    }
}

@Suite struct ArtworkPaletteTests {
    @Test func stableAndDifferentPerGenre() {
        let a = ArtworkPalette.make(genreKey: "deep-house", tint: .teal, dark: true)
        #expect(a == ArtworkPalette.make(genreKey: "deep-house", tint: .teal, dark: true))
        #expect(a != ArtworkPalette.make(genreKey: "techno", tint: .teal, dark: true))
        #expect(a.blobs.count == 3)
    }

    @Test func knownGenresGetTheirHuesAndTheLongestKeyWins() {
        #expect(ArtworkPalette.hue(for: "deep-house") == 0.72)
        #expect(ArtworkPalette.hue(for: "house") == 0.88)
        #expect(ArtworkPalette.hue(for: "Lo-Fi") == 0.07, "case-insensitive")
        #expect(ArtworkPalette.hue(for: "acid-jazz-classics") == 0.1)
        let unknown = ArtworkPalette.hue(for: "polka")
        #expect(unknown >= 0 && unknown < 1 && unknown == ArtworkPalette.hue(for: "polka"))
    }

    @Test func noGenreTakesTheTintsHue() {
        let none = ArtworkPalette.make(genreKey: nil, tint: .red, dark: false)
        let hue = none.base.0.hsb.hue
        let tintHue = ModernTint.red.hue
        #expect(min(abs(hue - tintHue), 1 - abs(hue - tintHue)) < 0.03)
        let graphite = ArtworkPalette.make(genreKey: nil, tint: .graphite, dark: true)
        #expect(graphite.base.0.hsb.saturation < 0.1, "graphite with nothing picked is neutral")
    }

    @Test func neighboursSteerAroundOlive() {
        // Orange turned towards yellow is fine (golden); green-yellow at mid brightness is avoided.
        #expect(abs(ArtworkPalette.neighbour(of: 0.07, by: 0.08) - 0.15) < 1e-9)
        #expect(abs(ArtworkPalette.neighbour(of: 0.1, by: 0.08) - 0.02) < 1e-9)
        #expect(abs(ArtworkPalette.neighbour(of: 0.25, by: 0.08) - 0.33) < 1e-9, "a hue already in the band keeps going")
        #expect(abs(ArtworkPalette.neighbour(of: 0.95, by: 0.1) - 0.05) < 1e-9, "wraps")
    }
}
