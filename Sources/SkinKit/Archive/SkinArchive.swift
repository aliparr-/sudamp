// SPDX-License-Identifier: GPL-3.0-or-later
// Picks the files a classic skin can use out of a .wsz, by whitelisted lower-cased basename (DESIGN §8.2).
// Matching follows Webamp's skinParserUtils (MIT): any folder depth, case-insensitive, .bmp or .png for images;
// images, viscolor.txt, region.txt and cursors take the LAST match in archive order (as Windows would after
// extracting duplicates), pledit.txt the FIRST (Webamp's getPlaylistStyle reads files[0]). Nothing else is
// ever inflated, so a hostile entry that is not on the list costs nothing.
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

/// The text files a skin may carry.
public enum SkinTextFile: String, CaseIterable, Sendable, Codable {
    case viscolor = "viscolor.txt"
    case pledit = "pledit.txt"
    case region = "region.txt"
}

public struct SkinArchive: Sendable {
    /// Image bytes per sheet basename ("main", "nums_ex", "genex", …) and the archive path they came from.
    public private(set) var images: [String: (path: String, data: Data)] = [:]
    public private(set) var texts: [SkinTextFile: (path: String, data: Data)] = [:]
    public private(set) var cursors: [String: (path: String, data: Data)] = [:]
    /// Whitelisted entries that could not be extracted (bad method, encryption, size mismatch, corruption).
    public private(set) var entryErrors: [(path: String, error: ZipError)] = []
    /// Archive entries that are not on the whitelist and were skipped without inflating.
    public private(set) var ignoredCount = 0
    public let entryCount: Int

    /// Sheet basenames worth extracting: every sheet in the sprite table plus genex.bmp (gen window colours).
    public static let imageNames: Set<String> = Set(SpriteSheet.allCases.map(\.fileBase) + ["genex"])
    /// Cursor basenames Webamp knows (skinParser.js CURSORS), without the .cur extension.
    public static let cursorNames: Set<String> = [
        "close", "eqclose", "eqnormal", "eqslid", "eqtitle", "mainmenu", "mmenu", "min", "normal", "pclose",
        "pnormal", "posbar", "psize", "ptbar", "pvscroll", "pwinbut", "pwsnorm", "pwssize", "songname", "titlebar",
        "volbal", "winbut", "wsnormal", "wsposbar",
    ]

    /// What a whitelisted basename is, if anything.
    enum Kind: Equatable {
        case image(String)
        case text(SkinTextFile)
        case cursor(String)
    }

    static func classify(_ basename: String) -> Kind? {
        let lower = basename.lowercased()
        guard let dot = lower.lastIndex(of: ".") else { return nil }
        let stem = String(lower[..<dot]), ext = String(lower[lower.index(after: dot)...])
        switch ext {
        case "bmp", "png": return imageNames.contains(stem) ? .image(stem) : nil
        case "txt": return SkinTextFile(rawValue: lower).map(Kind.text)
        case "cur": return cursorNames.contains(stem) ? .cursor(stem) : nil
        default: return nil
        }
    }

    /// Selects and extracts the whitelisted entries. Throws only for archive-level failures (not a zip, caps).
    public init(_ archive: ZipArchive) throws {
        entryCount = archive.entries.count
        var chosenImages: [String: ZipArchive.Entry] = [:]
        var chosenTexts: [SkinTextFile: ZipArchive.Entry] = [:]
        var chosenCursors: [String: ZipArchive.Entry] = [:]
        for entry in archive.entries where !entry.isDirectory {
            switch Self.classify(entry.basename) {
            case .image(let name): chosenImages[name] = entry  // last match wins
            case .text(.pledit): if chosenTexts[.pledit] == nil { chosenTexts[.pledit] = entry }  // first match
            case .text(let file): chosenTexts[file] = entry
            case .cursor(let name): chosenCursors[name] = entry
            case nil: ignoredCount += 1
            }
        }
        // Deterministic extraction order, and one total-size check over everything we will inflate.
        let imageKeys = chosenImages.keys.sorted()
        let textKeys = SkinTextFile.allCases.filter { chosenTexts[$0] != nil }
        let cursorKeys = chosenCursors.keys.sorted()
        let wanted = imageKeys.map { chosenImages[$0]! } + textKeys.map { chosenTexts[$0]! } + cursorKeys.map { chosenCursors[$0]! }
        let results = try archive.contents(of: wanted)

        var index = 0
        func take(_ entry: ZipArchive.Entry) -> Data? {
            defer { index += 1 }
            switch results[index] {
            case .success(let data): return data
            case .failure(let error):
                entryErrors.append((entry.path, error))
                return nil
            }
        }
        for key in imageKeys {
            let entry = chosenImages[key]!
            if let data = take(entry) { images[key] = (entry.path, data) }
        }
        for key in textKeys {
            let entry = chosenTexts[key]!
            if let data = take(entry) { texts[key] = (entry.path, data) }
        }
        for key in cursorKeys {
            let entry = chosenCursors[key]!
            if let data = take(entry) { cursors[key] = (entry.path, data) }
        }
    }

    /// Builds the selection from loose files (`name -> bytes`), e.g. a generated skin before it is zipped.
    public init(files: [(path: String, data: Data)]) {
        entryCount = files.count
        for (path, data) in files {
            let basename = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
            switch Self.classify(basename) {
            case .image(let name): images[name] = (path, data)
            case .text(.pledit): if texts[.pledit] == nil { texts[.pledit] = (path, data) }
            case .text(let file): texts[file] = (path, data)
            case .cursor(let name): cursors[name] = (path, data)
            case nil: ignoredCount += 1
            }
        }
    }
}
