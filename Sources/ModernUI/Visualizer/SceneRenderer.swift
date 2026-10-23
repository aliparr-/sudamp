// SPDX-License-Identifier: GPL-3.0-or-later
// Runs the visualiser's scenes: the one showing, a cross-fade when it changes (a pick, or the rotation moving on),
// the rotation's timing, and the bitmap each frame is drawn into. No AppKit: the artwork view hands it frames and
// shows the images it returns; tests and the preview's contact sheets use it offscreen.

import CoreGraphics
import Foundation

nonisolated final class SceneRenderer {
    typealias Mode = ModernPlayerState.Visualizer

    /// The scene showing (nil before the first `show`).
    private(set) var mode: Mode?
    private var scene: (any VisualizerScene)?
    /// The scene fading out, and how far the fade has gone (0...1).
    private var outgoing: (any VisualizerScene)?
    private(set) var fade: Double = 1
    var fadeDuration = 0.9
    var style = SceneStyle.standard
    private var seed: UInt64
    private var canvas: (context: CGContext, width: Int, height: Int)?

    init(seed: UInt64 = 1) { self.seed = seed }

    var isFading: Bool { outgoing != nil }

    /// Shows `mode` (a scene). Animated, the scene showing fades out while the new one fades in.
    func show(_ mode: Mode, animated: Bool) {
        guard mode.isScene, mode != self.mode else { return }
        seed &+= 0x9E37_79B9
        let next = mode.makeScene(seed: seed)
        if animated, let scene {
            outgoing = scene
            fade = 0
        } else {
            outgoing = nil
            fade = 1
        }
        scene = next
        self.mode = mode
    }

    /// Moves every scene on by `dt` with `input`, and the fade.
    func update(_ input: VisualizerInput, dt: Double) {
        scene?.update(input, dt: dt)
        if let outgoing {
            outgoing.update(input, dt: dt)
            fade = min(1, fade + dt / max(fadeDuration, 0.01))
            if fade >= 1 { self.outgoing = nil }
        }
    }

    /// The glow the scene showing wants (blended through a fade), 0...1.
    var glow: Double {
        let current = scene?.glow ?? 0
        guard let outgoing else { return current }
        return outgoing.glow + (current - outgoing.glow) * fade
    }

    /// Draws the scenes into `ctx` (points, origin top-left), cross-fading.
    func draw(in ctx: CGContext, size: CGSize) {
        if let outgoing {
            let t = fade * fade * (3 - 2 * fade)
            layer(ctx, alpha: 1 - t) { outgoing.draw(in: ctx, size: size, style: style) }
            if let scene { layer(ctx, alpha: t) { scene.draw(in: ctx, size: size, style: style) } }
        } else {
            scene?.draw(in: ctx, size: size, style: style)
        }
    }

    private func layer(_ ctx: CGContext, alpha: Double, _ body: () -> Void) {
        guard alpha > 0.002 else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// The current frame as an image `size` points across at `scale` pixels per point.
    func image(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        if canvas == nil || canvas?.width != width || canvas?.height != height {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            canvas = (context, width, height)
        }
        guard let ctx = canvas?.context else { return nil }
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // Points, top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        draw(in: ctx, size: size)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

/// When the rotation moves on: every `interval` seconds of music, to the next scene in the menus' order.
nonisolated struct VisualizerRotation: Equatable {
    var interval: Double
    /// Seconds the current scene has shown.
    private(set) var elapsed: Double = 0

    init(interval: Double) { self.interval = interval }

    /// Advances by `dt`; true when it is time for the next scene (and the clock starts again).
    mutating func advance(_ dt: Double) -> Bool {
        elapsed += max(0, dt)
        guard elapsed >= max(interval, 1) else { return false }
        elapsed = 0
        return true
    }

    mutating func restart() { elapsed = 0 }

    /// The scene after `mode` in the rotation.
    static func next(after mode: ModernPlayerState.Visualizer?) -> ModernPlayerState.Visualizer {
        (mode ?? .off).nextScene
    }
}
