// SPDX-License-Identifier: GPL-3.0-or-later
// Spectrum: 19 rounded bars standing on the bottom of the artwork, a cap over each that holds at the peak and then
// falls, and a soft reflection under them.

import CoreGraphics

nonisolated final class SpectrumScene: VisualizerScene {
    private var levels = [Float](repeating: 0, count: VisualizerInput.barCount)
    private var caps = [Float](repeating: 0, count: VisualizerInput.barCount)

    var glow: Double { 1 }

    func update(_ input: VisualizerInput, dt: Double) {
        // A touch of smoothing on the analyser's own falloff: quick to rise, gentle to fall.
        let rise = Float(1 - pow(0.3, dt * 30)), fall = Float(1 - pow(0.65, dt * 30))
        for i in levels.indices {
            let target = i < input.bars.count ? input.bars[i] : 0
            levels[i] += (target - levels[i]) * (target > levels[i] ? rise : fall)
            let peak = i < input.peaks.count ? max(input.peaks[i], levels[i]) : levels[i]
            caps[i] = max(peak, caps[i] - Float(dt) * 0.9)
        }
    }

    /// The bars' area: the lower part of the artwork, inset like the classic layout.
    static func barsRect(_ size: CGSize) -> CGRect {
        let inset = size.width * 0.12
        return CGRect(x: inset, y: size.height * 0.36, width: size.width - inset * 2, height: size.height * 0.64 - inset * 0.95)
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let rect = Self.barsRect(size)
        let n = levels.count
        let gap = rect.width / CGFloat(n) * 0.34
        let width = max(1, (rect.width - gap * CGFloat(n - 1)) / CGFloat(n))
        let bars = CGMutablePath()
        var reflection: [CGRect] = [], fade: [CGRect] = []
        reflection.reserveCapacity(n)
        fade.reserveCapacity(n)
        for (i, level) in levels.enumerated() {
            let h = max(width, rect.height * CGFloat(min(max(level, 0), 1)))
            let x = rect.minX + CGFloat(i) * (width + gap)
            bars.addRoundedRect(in: CGRect(x: x, y: rect.maxY - h, width: width, height: h), cornerWidth: width / 2,
                                cornerHeight: width / 2)
            // The reflection under each bar, in two fading bands (solid fills cost far less than a clipped gradient).
            let r = min(h * 0.22, size.height - rect.maxY - 1)
            if r > 0.5 {
                reflection.append(CGRect(x: x, y: rect.maxY + 1.2, width: width, height: r * 0.5))
                fade.append(CGRect(x: x, y: rect.maxY + 1.2 + r * 0.5, width: width, height: r * 0.5))
            }
        }
        ctx.addPath(bars)
        ctx.setFill(style.ink, style.isLight ? 0.92 : 0.9)
        ctx.fillPath()
        ctx.setFill(style.ink, 0.18)
        ctx.fill(reflection)
        ctx.setFill(style.ink, 0.07)
        ctx.fill(fade)
        // Caps: a thin line a little above each bar while it falls back.
        var caps: [CGRect] = []
        for (i, cap) in self.caps.enumerated() where cap > levels[i] + 0.04 {
            let x = rect.minX + CGFloat(i) * (width + gap)
            caps.append(CGRect(x: x, y: rect.maxY - rect.height * CGFloat(min(cap, 1)) - 2, width: width, height: max(1, width * 0.45)))
        }
        ctx.setFill(style.isLight ? style.ink : style.accent.mixed(with: .white, 0.5), 0.95)
        ctx.fill(caps)
    }
}
