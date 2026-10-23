// SPDX-License-Identifier: GPL-3.0-or-later
// Oscilloscope: the waveform as a smooth glowing trace across the artwork, leaving a short afterglow of the traces
// before it, like a phosphor screen.

import CoreGraphics

nonisolated final class ScopeScene: VisualizerScene {
    private var samples = [Float](repeating: 0, count: VisualizerInput.scopeCount)
    /// The last few traces, newest last, for the afterglow.
    private var history: [[Float]] = []
    private var sinceTrail: Double = 0

    var glow: Double { 1 }

    func update(_ input: VisualizerInput, dt: Double) {
        sinceTrail += dt
        if sinceTrail >= 1.0 / 30 {
            sinceTrail = 0
            history.append(samples)
            if history.count > 3 { history.removeFirst() }
        }
        // Gain rides the level a little, so quiet passages still show a shape.
        let gain = 1 + (1 - min(input.level * 2, 1)) * 0.6
        for i in samples.indices {
            let s = i < input.scope.count ? input.scope[i] * gain : 0
            samples[i] += (min(max(s, -1), 1) - samples[i]) * Float(min(1, dt * 40))
        }
    }

    /// The samples as points across `rect` (-1 at the bottom, 1 at the top).
    static func points(_ samples: [Float], in rect: CGRect) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        return samples.enumerated().map { i, s -> CGPoint in
            let v = CGFloat(min(max(s.isFinite ? s : 0, -1), 1))
            return CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(samples.count - 1), y: rect.midY - v * rect.height / 2)
        }
    }

    /// A smooth trace through the samples, Catmull-Rom through the points, across `rect`.
    static func path(_ samples: [Float], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let points = points(samples, in: rect)
        guard points.count > 1 else { return path }
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// The trace as a thin filled ribbon `width` across: the Catmull-Rom curve sampled twice per segment, offset
    /// either side along its normal. Filling it costs a fraction of stroking the curve.
    static func ribbon(_ samples: [Float], in rect: CGRect, width: CGFloat, smooth: Bool = true) -> CGPath {
        let points = points(samples, in: rect)
        let path = CGMutablePath()
        guard points.count > 1 else { return path }
        var line: [CGPoint] = []
        if smooth {
            line.reserveCapacity(points.count * 2)
            for i in 0..<(points.count - 1) {
                let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
                line.append(p1)
                // The curve's midpoint between p1 and p2.
                let mx = (-p0.x + 9 * p1.x + 9 * p2.x - p3.x) / 16, my = (-p0.y + 9 * p1.y + 9 * p2.y - p3.y) / 16
                line.append(CGPoint(x: mx, y: my))
            }
            line.append(points[points.count - 1])
        } else {
            line = points
        }
        let half = width / 2
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(line.count)
        right.reserveCapacity(line.count)
        for i in line.indices {
            let a = line[max(i - 1, 0)], b = line[min(i + 1, line.count - 1)]
            var nx = -(b.y - a.y), ny = b.x - a.x
            let length = (nx * nx + ny * ny).squareRoot()
            if length > 0 {
                nx /= length
                ny /= length
            }
            left.append(CGPoint(x: line[i].x + nx * half, y: line[i].y + ny * half))
            right.append(CGPoint(x: line[i].x - nx * half, y: line[i].y - ny * half))
        }
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let inset = size.width * 0.1
        let rect = CGRect(x: inset, y: size.height * 0.24, width: size.width - inset * 2, height: size.height * 0.56)
        // A faint centre line, like a graticule.
        ctx.setFill(style.ink, 0.12)
        ctx.fill(CGRect(x: rect.minX, y: rect.midY - 0.3, width: rect.width, height: 0.6))
        // The afterglow: the older traces through their samples alone (faint, nobody sees the corners).
        for (age, trace) in history.enumerated() {
            ctx.addPath(Self.ribbon(trace, in: rect, width: 1.1, smooth: false))
            ctx.setFill(style.ink, 0.07 + 0.07 * Double(age))
            ctx.fillPath()
        }
        ctx.addPath(Self.ribbon(samples, in: rect, width: 1.7))
        ctx.setFill(style.ink, 0.95)
        ctx.fillPath()
    }
}
