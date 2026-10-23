// SPDX-License-Identifier: GPL-3.0-or-later
// The modern skin's look (DESIGN §8.4): light or dark (or following the system), and a tint that colours the glass,
// the accent (play button, sliders, the EQ curve, the playing station) and the generated artwork. The colour maths
// is pure and unit-tested; the AppKit side resolves it into a `ModernPalette` for the current appearance.

import AppKit

/// Light, dark, or following the system.
nonisolated public enum ModernAppearance: String, CaseIterable, Sendable {
    case auto, light, dark

    public static let `default` = ModernAppearance.auto

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// An sRGB colour, 0...1 per channel: what the palette is made of before AppKit sees it.
nonisolated public struct RGB: Equatable, Sendable, CustomStringConvertible {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = Self.clamp(r)
        self.g = Self.clamp(g)
        self.b = Self.clamp(b)
    }

    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// From hue, saturation and brightness, each 0...1 (hue wraps).
    public init(hue: Double, saturation: Double, brightness: Double) {
        let h = (hue - hue.rounded(.down)) * 6
        let s = Self.clamp(saturation), v = Self.clamp(brightness)
        let i = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: self.init(v, t, p)
        case 1: self.init(q, v, p)
        case 2: self.init(p, v, t)
        case 3: self.init(p, q, v)
        case 4: self.init(t, p, v)
        default: self.init(v, p, q)
        }
    }

    /// Hue, saturation and brightness, each 0...1.
    public var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var hue = 0.0
        if delta > 0 {
            if maxC == r {
                hue = (g - b) / delta
            } else if maxC == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maxC == 0 ? 0 : delta / maxC, maxC)
    }

    /// WCAG relative luminance.
    public var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio against another colour (1...21).
    public func contrast(with other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `amount` of the way to `other` (0 = self, 1 = other).
    public func mixed(with other: RGB, _ amount: Double) -> RGB {
        let t = Self.clamp(amount)
        return RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    /// The same colour with its hue turned by `delta` (wrapping) and saturation and brightness scaled.
    public func adjusted(hue delta: Double = 0, saturation: Double = 1, brightness: Double = 1) -> RGB {
        let c = hsb
        return RGB(hue: c.hue + delta, saturation: c.saturation * saturation, brightness: c.brightness * brightness)
    }

    public var hex: UInt32 {
        UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }

    public var description: String { String(format: "#%06X", hex) }

    static func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    public static let white = RGB(1, 1, 1)
    public static let black = RGB(0, 0, 0)
}

/// The tints the user can choose. Teal, the app icon's colour, is the default.
nonisolated public enum ModernTint: String, CaseIterable, Sendable {
    case graphite, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink

    public static let `default` = ModernTint.teal

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The accent on light and dark glass. Light-mode accents are deep enough for white glyphs on them and for
    /// accent text on light glass; dark-mode accents are brighter.
    public var accent: (light: RGB, dark: RGB) {
        switch self {
        case .graphite: (RGB(hex: 0x5B5B63), RGB(hex: 0xB4B4BE))
        case .red: (RGB(hex: 0xE5383B), RGB(hex: 0xFF5A5F))
        case .orange: (RGB(hex: 0xE8710A), RGB(hex: 0xFF9F2E))
        case .yellow: (RGB(hex: 0xC99400), RGB(hex: 0xFFD23F))
        case .green: (RGB(hex: 0x23A049), RGB(hex: 0x3EDC6E))
        case .mint: (RGB(hex: 0x00A39A), RGB(hex: 0x5FEAD9))
        case .teal: (RGB(hex: 0x0D9488), RGB(hex: 0x2DD4BF))
        case .cyan: (RGB(hex: 0x0A8FD1), RGB(hex: 0x5AC8FA))
        case .blue: (RGB(hex: 0x0A6CFF), RGB(hex: 0x4C9DFF))
        case .indigo: (RGB(hex: 0x4F46E5), RGB(hex: 0x8B85FF))
        case .purple: (RGB(hex: 0x9D3FD8), RGB(hex: 0xC77DFF))
        case .pink: (RGB(hex: 0xE5266A), RGB(hex: 0xFF5C8D))
        }
    }

    /// The partner colour gradients run to: a neighbouring hue, a little deeper.
    public func deep(dark: Bool) -> RGB {
        let base = dark ? accent.dark : accent.light
        if self == .graphite { return base.adjusted(brightness: dark ? 0.78 : 0.72) }
        return base.adjusted(hue: -0.045, saturation: 1.08, brightness: dark ? 0.86 : 0.8)
    }

    /// How strongly the glass takes the tint (0 = clear glass).
    public func glassStrength(dark: Bool) -> Double {
        switch self {
        case .graphite: 0
        case .yellow: dark ? 0.2 : 0.26
        default: dark ? 0.26 : 0.22
        }
    }

    /// A hue for genres the artwork has no colour for: this tint's.
    public var hue: Double { accent.light.hsb.hue }
}

/// The colours of one generated artwork: a base gradient and three light blobs.
nonisolated public struct ArtworkPalette: Equatable, Sendable {
    /// Top-left and bottom-right of the base gradient.
    public var base: (RGB, RGB)
    /// The light blobs drifting over it.
    public var blobs: [RGB]

    public static func == (a: ArtworkPalette, b: ArtworkPalette) -> Bool {
        a.base.0 == b.base.0 && a.base.1 == b.base.1 && a.blobs == b.blobs
    }

    /// Every genre gets its own colours, stable across launches: a deep-to-mid gradient of neighbouring hues with
    /// blobs of light over it, like album art. The genre's hue family alone (mixing in a far-off tint would only make
    /// mud); with no genre picked the artwork takes the tint's hue.
    public static func make(genreKey: String?, tint: ModernTint, dark: Bool) -> ArtworkPalette {
        let tintColor = dark ? tint.accent.dark : tint.accent.light
        let hue = genreKey.map(hue(for:)) ?? tint.hue
        let neutral = genreKey == nil && tint == .graphite
        let saturation = neutral ? 0.06 : 1.0
        func tone(_ delta: Double, _ s: Double, _ b: Double) -> RGB {
            let h = neighbour(of: hue, by: delta)
            // Yellows need light to stay golden rather than olive.
            let golden = isYellow(h) ? max(b, 0.82) : b
            return RGB(hue: h, saturation: s * saturation, brightness: golden)
        }
        let deep = tone(0, 0.9, dark ? 0.28 : 0.36)
        let mid = tone(0.08, 0.78, dark ? 0.56 : 0.66)
        let highlight = tone(-0.05, 0.42, 1)
        let second = genreKey == nil && !neutral ? tintColor.adjusted(saturation: 0.95, brightness: 1.1) : tone(-0.12, 0.8, 0.95)
        let warm = tone(0.15, 0.85, 0.92)
        return ArtworkPalette(base: (deep, mid), blobs: [highlight, second, warm])
    }

    /// `hue` turned by `delta`, turned the other way instead when that would land in the yellow-green band (where
    /// mid-brightness colours read as olive) and the hue itself isn't there.
    static func neighbour(of hue: Double, by delta: Double) -> Double {
        let wrap = { (h: Double) in h - h.rounded(.down) }
        let turned = wrap(hue + delta)
        if delta != 0, isOlive(turned), !isOlive(wrap(hue)) { return wrap(hue - delta) }
        return turned
    }

    static func isOlive(_ hue: Double) -> Bool { (0.17...0.32).contains(hue) }
    static func isYellow(_ hue: Double) -> Bool { (0.1...0.2).contains(hue) }

    /// Hues for genres people know, so Lo-fi is warm and Ambient is cool; others hash their key (FNV-1a). The longest
    /// match wins (`deep-house` before `house`).
    static let curatedHues: [(key: String, hue: Double)] = [
        ("deep-house", 0.72), ("drum-and-bass", 0.015), ("lo-fi", 0.07), ("lofi", 0.07), ("synthwave", 0.86),
        ("downtempo", 0.5), ("classical", 0.12), ("ambient", 0.53), ("dubstep", 0.36), ("hip-hop", 0.04),
        ("techno", 0.6), ("trance", 0.76), ("garage", 0.32), ("minimal", 0.63), ("electro", 0.56), ("reggae", 0.3),
        ("breaks", 0.15), ("chill", 0.47), ("house", 0.88), ("disco", 0.83), ("jazz", 0.1), ("soul", 0.08),
        ("funk", 0.13), ("rock", 0.99), ("pop", 0.93), ("radio", 0.55),
    ].sorted { $0.key.count > $1.key.count }

    /// 0...1 for the genre's key.
    public static func hue(for key: String) -> Double {
        let lowered = key.lowercased()
        if let curated = curatedHues.first(where: { lowered.contains($0.key) }) { return curated.hue }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lowered.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Double(hash % 3600) / 3600
    }
}

// MARK: - AppKit

extension RGB {
    public var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    public func nsColor(alpha: Double) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    public var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    public func cgColor(alpha: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
}

extension ModernAppearance {
    /// What the window shows: nil follows the system.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension NSAppearance {
    public var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSColor {
    /// The colour resolved for `appearance` (CALayer colours don't follow the appearance by themselves).
    public func resolvedCGColor(in appearance: NSAppearance) -> CGColor {
        var color = cgColor
        appearance.performAsCurrentDrawingAppearance { color = self.cgColor }
        return color
    }
}

/// Every colour the modern skin draws with, resolved for one appearance and tint. Views get a new one whenever
/// either changes; system label colours are used for text so it stays legible on any glass.
public struct ModernPalette {
    public let isDark: Bool
    public let tint: ModernTint
    public let accent: RGB
    public let accentDeep: RGB
    /// Text and glyphs drawn on the accent (the play button).
    public let onAccent: RGB
    /// The glass's tint colour, nil for clear glass.
    public let glassTint: NSColor?
    public let appearance: NSAppearance

    public init(tint: ModernTint, appearance: NSAppearance) {
        let dark = appearance.isDark
        self.isDark = dark
        self.tint = tint
        self.appearance = appearance
        accent = dark ? tint.accent.dark : tint.accent.light
        accentDeep = tint.deep(dark: dark)
        onAccent = accent.contrast(with: .white) >= 2.2 ? .white : RGB(hex: 0x111114)
        let strength = tint.glassStrength(dark: dark)
        glassTint = strength > 0 ? accent.nsColor(alpha: strength) : nil
    }

    public var accentColor: NSColor { accent.nsColor }

    /// A system colour resolved for this palette's appearance.
    public func cg(_ color: NSColor) -> CGColor { color.resolvedCGColor(in: appearance) }

    /// Primary text.
    public var label: CGColor { cg(.labelColor) }
    public var secondaryLabel: CGColor { cg(.secondaryLabelColor) }
    public var tertiaryLabel: CGColor { cg(.tertiaryLabelColor) }

    /// Slider tracks and empty meters.
    public var track: CGColor { isDark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.12) }
    /// Hover wash behind glyph buttons and rows.
    public var hover: CGColor { isDark ? CGColor(gray: 1, alpha: 0.1) : CGColor(gray: 0, alpha: 0.065) }
    /// Pressed wash.
    public var pressed: CGColor { isDark ? CGColor(gray: 1, alpha: 0.17) : CGColor(gray: 0, alpha: 0.12) }
    /// Hairlines inside cards.
    public var separator: CGColor { isDark ? CGColor(gray: 1, alpha: 0.1) : CGColor(gray: 0, alpha: 0.08) }
    /// The specular sheen across the top of every card.
    public var sheen: CGColor { isDark ? CGColor(gray: 1, alpha: 0.07) : CGColor(gray: 1, alpha: 0.32) }
    /// Slider knobs.
    public var knob: CGColor { CGColor(gray: 1, alpha: 1) }
    /// Card drop shadows.
    public var shadow: CGColor { CGColor(gray: 0, alpha: 1) }
    public var shadowOpacity: Float { isDark ? 0.42 : 0.2 }
}
