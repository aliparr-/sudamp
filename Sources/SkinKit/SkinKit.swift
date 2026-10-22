// SPDX-License-Identifier: GPL-3.0-or-later
// SkinKit — pure classic-skin engine (DESIGN §4, §8): ZIP reader, sheets, sprite and layout tables, text-file
// parsers, region rasteriser, marquee, visualiser, window composer, hit-testing and the sudamp Dark generator.
// No AppKit or AVFoundation: CoreGraphics/ImageIO decode sheets, Compression inflates, everything else is Swift.

/// Module identity, for smoke tests and `--selftest` listings.
public enum SkinKitModule {
    public static let name = "SkinKit"
    /// Webamp commit the sprite table, FONT_LOOKUP and parser semantics were taken from.
    public static let webampCommit = "7734cd3c7cf144bab2d8614ce9f9ba2ff21e163e"
}
