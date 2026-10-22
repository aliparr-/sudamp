// SPDX-License-Identifier: GPL-3.0-or-later
// Maps arbitrary titles onto text.bmp's character set (DESIGN §8.3). Webamp's Character component deburrs and
// lower-cases each character and looks it up in FONT_LOOKUP (`<>{}` share the `[]` glyphs); characters it cannot
// map draw nothing. sudamp adds two things: typographic punctuation is folded to ASCII first, and a title with
// characters no skin font can show (CJK, Cyrillic, emoji…) is flagged so the UI can switch to a system font, or
// transliterated to Latin when the user asked for the skin font only. The deburr letter table follows lodash's
// `deburr` (which Webamp uses); the marquee model is Webamp's.
//
// Notices for the sources named above:
//
// Webamp — The MIT License (MIT), Copyright (c) [2015] [Jordan Eldredge]
// lodash — MIT License, Copyright OpenJS Foundation and other contributors <https://openjsf.org/>
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

public enum SkinFontText {
    /// lodash `deburr`'s letter table (Latin-1 Supplement and Latin Extended-A letters that do not decompose),
    /// as data; everything else loses its combining marks through NFD below.
    private static let deburred: [Character: String] = [
        "Æ": "Ae", "æ": "ae", "Ð": "D", "ð": "d", "Ø": "O", "ø": "o", "Þ": "Th", "þ": "th", "ß": "ss",
        "Đ": "D", "đ": "d", "Ħ": "H", "ħ": "h", "ı": "i", "Ĳ": "IJ", "ĳ": "ij", "ĸ": "k", "Ŀ": "L", "ŀ": "l",
        "Ł": "L", "ł": "l", "ŉ": "'n", "Ŋ": "N", "ŋ": "n", "Œ": "Oe", "œ": "oe", "Ŧ": "T", "ŧ": "t", "ſ": "s",
        "×": " ", "÷": " ",
    ]

    /// Typographic characters folded to what text.bmp has, before deburring (a sudamp addition).
    private static let punctuation: [Character: Character] = [
        "–": "-", "—": "-", "−": "-", "‐": "-", "‑": "-", "‒": "-",
        "‘": "'", "’": "'", "‚": "'", "′": "'", "`": "'", "´": "'",
        "“": "\"", "”": "\"", "„": "\"", "″": "\"",
        "\t": " ", "\n": " ", "\r": " ", "\u{00A0}": " ", "\u{2009}": " ", "\u{202F}": " ",
        "•": "*", "·": "*",
    ]

    /// lodash-style deburr, extended to all of Latin through NFD: accents and other combining marks removed.
    public static func deburr(_ text: String) -> String {
        var out = ""
        for character in text {
            // ASCII has nothing to strip (and NFD per character is slow: it ran on every marquee step).
            if character.isASCII {
                out.append(character)
                continue
            }
            if let mapped = deburred[character] {
                out += mapped
                continue
            }
            let decomposed = String(character).decomposedStringWithCanonicalMapping.unicodeScalars.filter {
                !(0x0300...0x036F).contains($0.value) && !(0x1AB0...0x1AFF).contains($0.value)
                    && !(0x1DC0...0x1DFF).contains($0.value) && !(0x20D0...0x20FF).contains($0.value)
                    && !(0xFE20...0xFE2F).contains($0.value)
            }
            // Keep the original if stripping removed everything (a lone combining mark).
            out += decomposed.isEmpty ? String(character) : String(String.UnicodeScalarView(decomposed))
        }
        return out
    }

    /// Result of fitting a title to the skin font.
    public struct Mapped: Equatable, Sendable {
        /// Characters in FONT_LOOKUP key form (lower case), one per drawn cell; unmappable ones are kept as-is
        /// and draw nothing, as in Webamp.
        public var characters: [Character]
        /// True when some character is outside ASCII and has no text.bmp glyph (CJK, Cyrillic, emoji, …).
        public var needsFallback: Bool

        public var text: String { String(characters) }
    }

    /// Folds punctuation, deburrs and lower-cases, then checks every character against FONT_LOOKUP.
    public static func map(_ text: String) -> Mapped {
        let folded = String(text.map { punctuation[$0] ?? $0 })
        var characters: [Character] = []
        var needsFallback = false
        for character in deburr(folded).lowercased() {
            characters.append(character)
            if FontLookup.cells[character] == nil, character.unicodeScalars.contains(where: { $0.value > 0x7E }) {
                needsFallback = true
            }
        }
        return Mapped(characters: characters, needsFallback: needsFallback)
    }

    /// Latin transliteration (ICU Any-Latin through Foundation), then deburred: "東京" -> "dong jing",
    /// "Привет" -> "privet". Characters with no Latin form (emoji) remain and draw nothing.
    public static func transliterate(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        return deburr(latin)
    }

    /// Glyph-cell string for fixed-width readouts (kbps, khz, mini time): right-aligned, padded with spaces.
    public static func rightAligned(_ text: String, width: Int) -> String {
        let trimmed = String(text.suffix(width))
        return String(repeating: " ", count: max(0, width - trimmed.count)) + trimmed
    }
}

/// Webamp's marquee model (components/MainWindow/Marquee.tsx @ 7734cd3, MIT © 2015 Jordan Eldredge): 31
/// characters fit; longer text loops with a separator and moves one 5 px character every 220 ms; stepping
/// resumes 1 s after a drag ends.
public enum MarqueeModel {
    public static let separator = "  ***  "
    public static let characterWidth = 5
    public static let maxLength = 31
    public static let stepInterval: Double = 0.220
    public static let resumeDelay: Double = 1.0

    /// Always-positive modulus.
    public static func mod(_ n: Int, _ m: Int) -> Int { ((n % m) + m) % m }

    public static func isLong(_ length: Int) -> Bool { length >= maxLength }

    /// How many pixels the text is shifted left at `step`, plus a drag offset in pixels.
    public static func stepOffset(length: Int, step: Int, pixels: Int) -> Int {
        guard isLong(length) else { return 0 }
        let steps = length + separator.count
        let stringLength = steps * characterWidth
        // mod(step * 5 + pixels, stringLength), reduced first so huge steps cannot overflow.
        return mod(mod(step, steps) * characterWidth + mod(pixels, stringLength), stringLength)
    }

    public static func stepOffset(_ text: String, step: Int, pixels: Int) -> Int {
        stepOffset(length: text.count, step: step, pixels: pixels)
    }

    /// Text wider than the marquee loops; shorter text is padded to 31 characters.
    public static func loopText(_ text: String) -> String {
        isLong(text.count) ? text + separator + text : text.padding(toLength: maxLength, withPad: " ", startingAt: 0)
    }

    /// The step reached `elapsed` seconds after scrolling (re)started.
    public static func step(elapsed: Double) -> Int {
        elapsed <= 0 ? 0 : Int((elapsed / stepInterval).rounded(.down))
    }
}
