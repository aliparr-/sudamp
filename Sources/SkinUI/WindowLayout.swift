// SPDX-License-Identifier: GPL-3.0-or-later
// The window layout file (frame persistence, DESIGN §3 "layout, skin, scale … are restored"): where each window's
// top-left corner is, whether it is open and shaded, the scale and always-on-top. Positions are AppKit global
// coordinates of the top-left corner (x, maxY), so a window restores in place whatever its size became (shade,
// scale, another skin). Written atomically as JSON to a URL the app chooses (e.g. <profile>/layout.json).
//
// Shape follows MacAmp's WindowFrameStore/PersistedWindowFrame idea (hfyeomans/MacAmp @ cb0c77f, MIT © 2025-2026
// Hank Yeomans), rewritten for a file instead of UserDefaults.

import Foundation

nonisolated public struct WindowLayout: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        /// AppKit global x of the left edge.
        public var x: Double
        /// AppKit global y of the top edge (frame.maxY).
        public var top: Double
        public var open: Bool
        public var shaded: Bool

        public init(x: Double, top: Double, open: Bool, shaded: Bool) {
            self.x = x
            self.top = top
            self.open = open
            self.shaded = shaded
        }
    }

    public var version = WindowLayout.currentVersion
    public var scale: Int
    public var alwaysOnTop: Bool
    public var windows: [String: Entry]

    public init(scale: Int, alwaysOnTop: Bool, windows: [SkinWindowRole: Entry]) {
        self.scale = scale
        self.alwaysOnTop = alwaysOnTop
        self.windows = Dictionary(uniqueKeysWithValues: windows.map { ($0.key.rawValue, $0.value) })
    }

    public func entry(_ role: SkinWindowRole) -> Entry? { windows[role.rawValue] }

    /// Loads a layout; nil when the file is missing, unreadable, from a newer version or nonsensical.
    public static func load(from url: URL) -> WindowLayout? {
        guard let data = try? Data(contentsOf: url),
              let layout = try? JSONDecoder().decode(WindowLayout.self, from: data),
              layout.version <= currentVersion, SkinScale.allowed.contains(layout.scale),
              layout.windows.values.allSatisfy({ $0.x.isFinite && $0.top.isFinite && abs($0.x) < 1e6 && abs($0.top) < 1e6 })
        else { return nil }
        return layout
    }

    /// Writes the layout atomically, creating the parent directory.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
