// SPDX-License-Identifier: GPL-3.0-or-later
// The original "sudamp Dark" skin (DESIGN §8.3): generated in code, written as a classic .wsz by skingen, and
// used as the per-sheet fallback for every other skin. The committed Fixtures/skins/sudamp-dark.wsz must be
// byte-identical to `archive()` (tested, and checked by `skingen --check`).

import Foundation

public enum SudampDark {
    public static let fileName = "sudamp-dark.wsz"

    static let readme = """
        sudamp Dark
        ===========

        The original default skin of sudamp (The Sudden Amp), a free macOS player for classic skins.
        Drawn entirely in code by sudamp's skingen from flat fills, 1 px bevels and an original pixel font;
        it contains no Nullsoft artwork. The drawing routines are adapted from Bitamp (MIT, (c) 2026 Ryan
        Romanosky and Bitamp contributors); sprite positions follow Webamp's table (MIT, (c) 2015 Jordan
        Eldredge).

        Licence: GPL-3.0-or-later, like sudamp itself.

        """

    /// The skin's files (lower-case names) as `skingen` writes them.
    public static func files() -> [String: Data] {
        WszWriter.files(for: SudampDarkPainter())
    }

    /// The .wsz bytes: files sorted by name, fixed timestamps, deterministic DEFLATE.
    public static func archive() -> Data {
        let entries = files().sorted { $0.key < $1.key }.map { ZipWriter.Entry(path: $0.key, data: $0.value) }
        return ZipWriter.archive(entries)
    }

    /// The decoded skin, built once per process from the generated files (no bundle resource needed).
    public static let skin: Skin = {
        let selection = SkinArchive(files: files().sorted { $0.key < $1.key }.map { (path: $0.key, data: $0.value) })
        return SkinLoader.build(selection, name: "sudamp Dark", archiveBytes: 0, fallback: nil)
    }()
}
