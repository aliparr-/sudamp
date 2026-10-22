// SPDX-License-Identifier: GPL-3.0-or-later
//
// The colours a code-drawn skin is painted with. `SudampDarkPainter` draws every sprite from a theme, so a new
// look is a new theme rather than new drawing code.
//
// Ported from Bitamp, Sources/BitampKit/Skin/SkinTheme.swift
// (https://github.com/ryanromanov/Bitamp @ 91952819c9cc0394dd03a961dd27a101a52ee6ef).
// sudamp changes: only the flat-panel, ridged-title, bevelled-button style is kept (Bitamp's brushed, gloss, gel
// and Orb variants are dropped), colours are `RGBA`, and the only theme is the new "sudamp Dark" palette
// (near-black panels, graphite bevels, the icon's teal accent #0d9488/#14b8a6). No Bitamp themes or branding.
//
// Original notice:
//
// MIT License
//
// Copyright (c) 2026 Ryan Romanosky and Bitamp contributors
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

public struct SkinTheme: Sendable {
    public var id: String
    public var name: String
    /// Text on the title bars.
    public var title: String
    public var eqTitle: String

    public var face: RGBA
    public var faceButton: RGBA
    public var facePressed: RGBA
    public var faceLight: RGBA
    public var faceHighlight: RGBA
    public var faceDark: RGBA
    public var thumbPressed: RGBA
    public var titleBar: RGBA
    public var titleBarInactive: RGBA
    public var groove: RGBA
    /// Text printed on panels, like "KBPS".
    public var label: RGBA
    /// Icons and text on buttons.
    public var icon: RGBA
    public var iconDim: RGBA
    public var titleText: RGBA
    public var titleTextInactive: RGBA
    /// MONO and STEREO when they aren't lit.
    public var indicatorOff: RGBA

    public var lcd: RGBA
    public var lcdGhost: RGBA
    public var lcdOn: RGBA
    public var lcdDim: RGBA
    /// Lit LEDs, the pause sign, the about mark and the active title ridges.
    public var accent: RGBA
    public var accentDim: RGBA
    public var stopRed: RGBA
    /// Slider fills, from low to high.
    public var levelLow: RGBA
    public var levelMid: RGBA
    public var levelHigh: RGBA

    /// The visualizer's background dot grid.
    public var visGrid: RGBA
    /// Spectrum colours from the top bar row to the bottom, and the peak dots.
    public var spectrumTop: RGBA
    public var spectrumMiddle: RGBA
    public var spectrumBottom: RGBA
    public var peak: RGBA
    /// Equalizer graph, from +12 dB to -12 dB.
    public var graphTop: RGBA
    public var graphMiddle: RGBA
    public var graphBottom: RGBA
    public var playlistCurrent: RGBA
    public var playlistSelected: RGBA
}

/// sudamp's original default skin palette.
public enum SudampDarkTheme {
    /// Teal from assets/icon.svg (#0d9488) and its lighter companion (#14b8a6).
    public static let teal = RGBA(hex: 0x0D9488)
    public static let tealBright = RGBA(hex: 0x14B8A6)

    public static let theme = SkinTheme(
        id: "sudamp-dark", name: "sudamp Dark", title: "SUDAMP", eqTitle: "SUDAMP EQUALIZER",
        face: rgb(0x15171A), faceButton: rgb(0x1E2125), facePressed: rgb(0x101214),
        faceLight: rgb(0x3A3F46), faceHighlight: rgb(0x596069), faceDark: rgb(0x050607),
        thumbPressed: rgb(0x2E3339), titleBar: rgb(0x111316), titleBarInactive: rgb(0x16181B), groove: rgb(0x08090A),
        label: rgb(0x7E8791), icon: rgb(0xD3D9DF), iconDim: rgb(0x7E8791),
        titleText: tealBright, titleTextInactive: rgb(0x68707A), indicatorOff: rgb(0x2C3136),
        lcd: rgb(0x050908), lcdGhost: rgb(0x0C1C1A), lcdOn: tealBright, lcdDim: rgb(0x0A5650),
        accent: tealBright, accentDim: rgb(0x0B3F3A), stopRed: rgb(0xD9534F),
        levelLow: teal, levelMid: tealBright, levelHigh: rgb(0x99F6E4),
        visGrid: rgb(0x0E1A19),
        spectrumTop: rgb(0xCCFBF1), spectrumMiddle: tealBright, spectrumBottom: teal, peak: rgb(0xF0FDFA),
        graphTop: rgb(0x5EEAD4), graphMiddle: tealBright, graphBottom: teal,
        playlistCurrent: rgb(0xFFFFFF), playlistSelected: rgb(0x0F3D39))

    /// Text-file values derived from the theme, as written into viscolor.txt and pledit.txt.
    public static let palette = Palette(theme)

    public struct Palette: Sendable {
        public let viscolors: [RGBA]
        public let playlistStyle: PlaylistStyle
        public let eqGraphColors: [RGBA]

        init(_ theme: SkinTheme) {
            var colors = [theme.lcd, theme.visGrid]
            for i in 0..<16 {
                let t = Double(i) / 15
                colors.append(t < 0.45
                    ? mix(theme.spectrumTop, theme.spectrumMiddle, t / 0.45)
                    : mix(theme.spectrumMiddle, theme.spectrumBottom, (t - 0.45) / 0.55))
            }
            for i in 0..<5 {
                colors.append(mix(theme.lcdOn, theme.lcdDim, Double(i) / 4))
            }
            colors.append(theme.peak)
            viscolors = colors
            playlistStyle = PlaylistStyle(
                normal: theme.lcdOn, current: theme.playlistCurrent, normalBackground: theme.lcd,
                selectedBackground: theme.playlistSelected, font: "Arial")
            eqGraphColors = (0..<19).map { row in
                let t = Double(row) / 18
                return t < 0.5
                    ? mix(theme.graphTop, theme.graphMiddle, t * 2)
                    : mix(theme.graphMiddle, theme.graphBottom, (t - 0.5) * 2)
            }
        }
    }
}
