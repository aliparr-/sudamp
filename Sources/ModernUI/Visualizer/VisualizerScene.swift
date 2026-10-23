// SPDX-License-Identifier: GPL-3.0-or-later
// The visualiser's scenes (DESIGN §8.4). Each is a small animation drawn with Core Graphics into the artwork, 30
// times a second while something plays. A scene hears the music through `VisualizerInput` (the analyser's bars,
// peaks and scope, plus the bass, mids, treble and beats `AudioFeatures` picks out of them) and paints with the
// artwork palette's colours (`SceneStyle`). Scenes are plain classes that are deterministic for a seed and draw the
// same offscreen, so tests and the preview render them without a window.
//
// Scenes are drawn as bitmaps, not as animated Core Animation paths. A shape layer's in-flight path has a different
// element structure from the path it was built from, so starting each frame's animation from it blended the bars'
// corners into their neighbours: the bars tore into staggered fragments for a frame.

import CoreGraphics
import Foundation

/// What a scene hears, once per frame.
nonisolated struct VisualizerInput {
    /// 19 levels, 0...1, low to high frequency (the analyser's bars: instant rise, steady fall).
    var bars: [Float]
    /// Peak markers over the bars, 0...1.
    var peaks: [Float]
    /// 76 oscilloscope samples, -1...1, oldest first.
    var scope: [Float]
    /// Smoothed band energies, 0...1: bass (40–140 Hz), mids (140 Hz–2.5 kHz), treble (above).
    var bass: Float
    var mid: Float
    var treble: Float
    /// Overall loudness, 0...1, smoothed.
    var level: Float
    /// A kick (a sharp rise in the bass) landed this frame.
    var beat: Bool
    /// 1 on a kick, decaying to 0 over about half a second: for flashes.
    var pulse: Float
    /// Position in the current beat, 0..<1, from a clock that follows the kicks and keeps time through a break.
    var groove: Double
    /// The tempo the clock follows, in seconds per beat (0.3...1).
    var beatInterval: Double
    /// Kicks so far.
    var beats: Int
    /// Seconds of music the scene has heard.
    var time: Double

    static let barCount = ModernVisualizerFrame.barCount
    static let scopeCount = ModernVisualizerFrame.scopeCount

    static let silence = VisualizerInput(
        bars: [Float](repeating: 0, count: barCount), peaks: [Float](repeating: 0, count: barCount),
        scope: [Float](repeating: 0, count: scopeCount), bass: 0, mid: 0, treble: 0, level: 0, beat: false, pulse: 0,
        groove: 0, beatInterval: 0.5, beats: 0, time: 0)

    /// Whether anything is sounding.
    var isSilent: Bool { level < 0.02 }

    /// The level at `fraction` (0...1) of the way from the lowest bar to the highest, interpolated between bars.
    func band(at fraction: Double) -> Float {
        guard !bars.isEmpty else { return 0 }
        let x = min(max(fraction, 0), 1) * Double(bars.count - 1)
        let i = Int(x)
        let f = Float(x - Double(i))
        let a = bars[i], b = bars[min(i + 1, bars.count - 1)]
        return a + (b - a) * f
    }
}

/// The colours a scene paints with, from the artwork's palette.
nonisolated struct SceneStyle: Equatable {
    /// The main colour: near-white over dark artwork, a deep tint over light.
    var ink: RGB
    var glow: RGB
    /// A second colour for highlights.
    var accent: RGB
    /// Bright colours that belong with the artwork.
    var sparks: [RGB]
    /// The artwork's gradient, deep then mid (for scenes that paint a backdrop of their own).
    var deep: RGB
    var mid: RGB
    /// Light artwork: draw dark, with no additive light.
    var isLight: Bool

    init(_ palette: ArtworkPalette) {
        ink = palette.ink
        glow = palette.glow
        accent = palette.accent
        sparks = palette.sparks.isEmpty ? [palette.ink] : palette.sparks
        deep = palette.base.0
        mid = palette.base.1
        isLight = palette.isLight
    }

    static let standard = SceneStyle(ArtworkPalette.make(genreKey: nil, tint: .default, dark: true))

    /// The `i`th spark colour, wrapping.
    func spark(_ i: Int) -> RGB { sparks[((i % sparks.count) + sparks.count) % sparks.count] }
}

/// One of the visualiser's animations. Paused or stopped, the artwork shows a still frame drawn after 40 updates of
/// silence (60 for a scene that has not played yet), so a scene should come to rest within about half a second of
/// silence, and its rest should look calm and finished.
nonisolated protocol VisualizerScene: AnyObject {
    /// Moves on by `dt` seconds (1/60 to 1/10) with the newest audio.
    func update(_ input: VisualizerInput, dt: Double)
    /// Draws the current state into a cleared context in points, origin top-left, y down, over `size` (the artwork's
    /// square). The artwork's own gradient and light are already behind it.
    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle)
    /// How much of the artwork's glow suits it: 1 for bright shapes on the artwork, 0 for scenes that fill it.
    var glow: Double { get }
}

extension ModernPlayerState.Visualizer {
    /// A fresh scene for this mode (nil for `rotate` and `off`). `seed` varies the random parts (stars, crowds).
    nonisolated func makeScene(seed: UInt64 = 1) -> (any VisualizerScene)? {
        switch self {
        case .spectrum: SpectrumScene()
        case .oscilloscope: ScopeScene()
        case .leds: LEDScene()
        case .halo: HaloScene(seed: seed)
        case .waterfall: WaterfallScene()
        case .starfield: StarfieldScene(seed: seed)
        case .pixelDJ: PixelDJScene(seed: seed)
        case .toast: ToastScene(seed: seed)
        case .tunnel: TunnelScene(seed: seed)
        case .fireworks: FireworksScene(seed: seed)
        case .lava: LavaScene(seed: seed)
        case .rotate, .off: nil
        }
    }
}

/// A small, fast, seeded random source (xorshift64*), so scenes are the same every run for a seed.
nonisolated struct SceneRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed &* 0x2545_F491_4F6C_DD1D | 1 }

    /// 0..<1.
    mutating func next() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Double((state &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 53)
    }

    mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }

    mutating func int(_ upper: Int) -> Int { min(Int(next() * Double(upper)), upper - 1) }

    mutating func chance(_ p: Double) -> Bool { next() < p }
}

// MARK: - Drawing helpers

extension RGB {
    /// The same colour with brightness scaled (and clamped).
    nonisolated func scaled(_ factor: Double) -> RGB { RGB(r * factor, g * factor, b * factor) }
}

/// sRGB, made once (scenes build gradients every frame).
nonisolated let sceneColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

extension CGContext {
    nonisolated func setFill(_ color: RGB, _ alpha: Double = 1) { setFillColor(color.cgColor(alpha: alpha)) }
    nonisolated func setStroke(_ color: RGB, _ alpha: Double = 1) { setStrokeColor(color.cgColor(alpha: alpha)) }

    /// A soft round light: a radial gradient from `color` at `alpha` to clear.
    nonisolated func fillGlow(at center: CGPoint, radius: CGFloat, color: RGB, alpha: Double) {
        guard radius > 0, alpha > 0 else { return }
        let colors = [color.cgColor(alpha: alpha), color.cgColor(alpha: alpha * 0.35), color.cgColor(alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: sceneColorSpace, colors: colors, locations: [0, 0.45, 1]) else { return }
        drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
}

/// A low-resolution pixel grid for pixel-art scenes: drawn into as RGBA pixels, then scaled up with no smoothing
/// so every pixel stays a crisp square.
nonisolated struct PixelCanvas {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: 0, count: width * height)
    }

    mutating func clear() { pixels.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }

    /// Blends `color` at `alpha` over the pixel at (x, y), top-left origin; outside the grid does nothing.
    mutating func set(_ x: Int, _ y: Int, _ color: RGB, _ alpha: Double = 1) {
        guard x >= 0, y >= 0, x < width, y < height, alpha > 0 else { return }
        let i = y * width + x
        let a = min(alpha, 1)
        let old = pixels[i]
        // Stored premultiplied, as bytes R, G, B, A in memory.
        let oa = Double((old >> 24) & 0xFF) / 255
        let or = Double(old & 0xFF) / 255, og = Double((old >> 8) & 0xFF) / 255, ob = Double((old >> 16) & 0xFF) / 255
        let na = a + oa * (1 - a)
        let nr = color.r * a + or * (1 - a), ng = color.g * a + og * (1 - a), nb = color.b * a + ob * (1 - a)
        func byte(_ v: Double) -> UInt32 { UInt32(min(max(v, 0), 1) * 255 + 0.5) }
        pixels[i] = byte(nr) | byte(ng) << 8 | byte(nb) << 16 | byte(na) << 24
    }

    /// A filled rectangle of pixels (clipped to the grid).
    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: RGB, _ alpha: Double = 1) {
        let x0 = max(x, 0), x1 = min(x + max(w, 0), width), y0 = max(y, 0), y1 = min(y + max(h, 0), height)
        guard x0 < x1, y0 < y1 else { return }
        for yy in y0..<y1 {
            for xx in x0..<x1 { set(xx, yy, color, alpha) }
        }
    }

    /// Whether the pixel at (x, y) has anything in it.
    func isLit(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return pixels[y * width + x] >> 24 != 0
    }

    func makeImage() -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sceneColorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Draws the grid over `rect` (points, in a top-left-origin context) with hard pixel edges.
    func draw(in ctx: CGContext, rect: CGRect) {
        guard let image = makeImage() else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .none
        // The context is flipped (y down); images draw bottom-up, so flip back around the rect.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }
}
