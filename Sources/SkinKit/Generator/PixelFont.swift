// SPDX-License-Identifier: GPL-3.0-or-later
//
// An original 4x5 pixel font drawn in 5x6 cells like classic text.bmp. It draws sudamp Dark's labels and
// text.bmp, and the playlist rows of the 1x composer (deterministic, no system fonts).
//
// Ported from Bitamp, Sources/BitampKit/Skin/PixelFont.swift
// (https://github.com/ryanromanov/Bitamp @ 91952819c9cc0394dd03a961dd27a101a52ee6ef).
// sudamp changes: added original glyphs for the text.bmp cells Bitamp's font lacked (… ^ $ Å Ö Ä), so every
// FONT_LOOKUP cell has art; the rest is Bitamp's font unchanged.
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

import Foundation

public enum PixelFont {
    public static let cellWidth = 5
    public static let cellHeight = 6

    /// Uppercases, strips accents and maps typographic punctuation to what the font has.
    /// Anything still missing becomes "?".
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: nil).uppercased()
        return String(folded.map { character -> Character in
            switch character {
            case "–", "—", "−": return "-"
            case "‘", "’", "`": return "'"
            case "“", "”": return "\""
            case "\t", "\n", "\r": return " "
            default: return glyphs[character] == nil ? "?" : character
            }
        })
    }

    public static func width(of text: String) -> Int {
        text.count * cellWidth
    }

    /// A glyph trimmed to its lit columns, for tightly spaced labels. "I" drops its serifs.
    static func compactRows(for character: Character) -> [String] {
        if character == "I" { return Array(repeating: "#", count: 5) }
        let rows = rows(for: character)
        let lit = rows.flatMap { $0.enumerated().filter { $0.element == "#" }.map(\.offset) }
        guard let first = lit.min(), let last = lit.max() else { return rows }
        return rows.map { String(Array($0)[first...last]) }
    }

    /// Width of `text` laid out by `Canvas.compactText`, from the first lit pixel to the last.
    static func compactWidth(of text: String) -> Int {
        let widths = normalize(text).map { compactRows(for: $0)[0].count }
        return widths.reduce(0, +) + max(0, widths.count - 1)
    }

    /// Five rows of four pixels; "#" is lit.
    static func rows(for character: Character) -> [String] {
        glyphs[character] ?? glyphs["?"]!
    }

    static let glyphs: [Character: [String]] = [
        "A": [".##.", "#..#", "####", "#..#", "#..#"],
        "B": ["###.", "#..#", "###.", "#..#", "###."],
        "C": [".###", "#...", "#...", "#...", ".###"],
        "D": ["###.", "#..#", "#..#", "#..#", "###."],
        "E": ["####", "#...", "###.", "#...", "####"],
        "F": ["####", "#...", "###.", "#...", "#..."],
        "G": [".###", "#...", "#.##", "#..#", ".###"],
        "H": ["#..#", "#..#", "####", "#..#", "#..#"],
        "I": ["###.", ".#..", ".#..", ".#..", "###."],
        "J": ["..##", "...#", "...#", "#..#", ".##."],
        "K": ["#..#", "#.#.", "##..", "#.#.", "#..#"],
        "L": ["#...", "#...", "#...", "#...", "####"],
        "M": ["#..#", "####", "####", "#..#", "#..#"],
        "N": ["#..#", "##.#", "#.##", "#..#", "#..#"],
        "O": [".##.", "#..#", "#..#", "#..#", ".##."],
        "P": ["###.", "#..#", "###.", "#...", "#..."],
        "Q": [".##.", "#..#", "#..#", "#.#.", ".#.#"],
        "R": ["###.", "#..#", "###.", "#.#.", "#..#"],
        "S": [".###", "#...", ".##.", "...#", "###."],
        "T": ["###.", ".#..", ".#..", ".#..", ".#.."],
        "U": ["#..#", "#..#", "#..#", "#..#", ".##."],
        "V": ["#.#.", "#.#.", "#.#.", "#.#.", ".#.."],
        "W": ["#..#", "#..#", "####", "####", "#..#"],
        "X": ["#..#", "#..#", ".##.", "#..#", "#..#"],
        "Y": ["#.#.", "#.#.", ".#..", ".#..", ".#.."],
        "Z": ["####", "...#", ".##.", "#...", "####"],
        "0": [".##.", "#.##", "##.#", "#..#", ".##."],
        "1": [".#..", "##..", ".#..", ".#..", "###."],
        "2": ["###.", "...#", ".##.", "#...", "####"],
        "3": ["###.", "...#", ".##.", "...#", "###."],
        "4": ["#..#", "#..#", "####", "...#", "...#"],
        "5": ["####", "#...", "###.", "...#", "###."],
        "6": [".##.", "#...", "###.", "#..#", ".##."],
        "7": ["####", "...#", "..#.", ".#..", ".#.."],
        "8": [".##.", "#..#", ".##.", "#..#", ".##."],
        "9": [".##.", "#..#", ".###", "...#", ".##."],
        " ": ["....", "....", "....", "....", "...."],
        ".": ["....", "....", "....", "....", ".#.."],
        ",": ["....", "....", "....", ".#..", "#..."],
        ":": ["....", ".#..", "....", ".#..", "...."],
        ";": ["....", ".#..", "....", ".#..", "#..."],
        "-": ["....", "....", "###.", "....", "...."],
        "_": ["....", "....", "....", "....", "####"],
        "(": ["..#.", ".#..", ".#..", ".#..", "..#."],
        ")": [".#..", "..#.", "..#.", "..#.", ".#.."],
        "[": [".##.", ".#..", ".#..", ".#..", ".##."],
        "]": [".##.", "..#.", "..#.", "..#.", ".##."],
        "'": [".#..", ".#..", "....", "....", "...."],
        "\"": ["#.#.", "#.#.", "....", "....", "...."],
        "!": [".#..", ".#..", ".#..", "....", ".#.."],
        "?": ["###.", "...#", ".##.", "....", ".#.."],
        "/": ["...#", "...#", "..#.", ".#..", "#..."],
        "\\": ["#...", "#...", ".#..", "..#.", "...#"],
        "&": [".#..", "#.#.", ".#..", "#.#.", ".#.#"],
        "+": ["....", ".#..", "###.", ".#..", "...."],
        "=": ["....", "###.", "....", "###.", "...."],
        "#": ["#.#.", "###.", "#.#.", "###.", "#.#."],
        "@": [".##.", "#.##", "#.##", "#...", ".##."],
        "%": ["#..#", "...#", "..#.", ".#..", "#..#"],
        "*": ["....", "#.#.", ".#..", "#.#.", "...."],
        "<": ["..#.", ".#..", "#...", ".#..", "..#."],
        ">": [".#..", "..#.", "...#", "..#.", ".#.."],
        // sudamp additions (original art) for the remaining text.bmp cells.
        "…": [".....", ".....", ".....", ".....", "#.#.#"],
        "^": [".#..", "#.#.", "....", "....", "...."],
        "$": [".###", "##..", ".##.", "..##", "###."],
        "Å": [".##.", ".##.", "#..#", "####", "#..#"],
        "Ö": ["#..#", ".##.", "#..#", "#..#", ".##."],
        "Ä": ["#..#", ".##.", "#..#", "####", "#..#"],
    ]
}
