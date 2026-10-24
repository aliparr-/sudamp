// SPDX-License-Identifier: GPL-3.0-or-later
// Loops: the waveform drawn as a phase portrait, a glowing trace that plots each moment of the sound against the one
// a few samples before it. The analyser is mono, so this delay stands in for a stereo scope's second channel: a pure
// tone draws a clean ellipse, a bassline a big lazy loop, a busy mix a tangle of knots. The delay follows the sound's
// own pitch (a quarter of its period, so a tone comes out round) and drifts a little so the figure breathes, and the
// whole figure turns slowly, leaving an afterglow of its last few traces in the artwork's colour. Kicks swell it and
// brighten it; through a breakdown it turns slower and its afterglow lingers; the drop blooms with light. In silence it
// settles to a small, faint ring with the beam resting on it. A seed picks the way it turns and its afterglow's colour.

import CoreGraphics
import Foundation

nonisolated final class LoopsScene: VisualizerScene {
    /// Points along the trace: the scope's samples, resampled smoothly (Catmull-Rom) so the curve has no corners.
    private static let resolution = 121
    /// The longest afterglow (in a breakdown), in traces kept at 30 a second.
    private static let maxTrail = 7
    /// The resting ring's radius, as a share of the figure's.
    private static let restRadius = 0.27

    /// The scope's samples, centred and softened, and a copy for softening from.
    private var samples = [Double](repeating: 0, count: VisualizerInput.scopeCount)
    private var raw = [Double](repeating: 0, count: VisualizerInput.scopeCount)
    private var weights = [Double](repeating: 0, count: 16)
    /// The plot along its two diagonals, before scaling.
    private var us = [Double](repeating: 0, count: resolution)
    private var vs = [Double](repeating: 0, count: resolution)
    /// The newest trace, centred, in shares of the figure's radius (y down).
    private var trace = [CGPoint](repeating: .zero, count: resolution)
    /// Earlier traces for the afterglow, end to end in a ring buffer of `maxTrail`; `trailCount` of them are in use,
    /// the newest at `trailHead`.
    private var trails = [CGPoint](repeating: .zero, count: resolution * maxTrail)
    private var trailHead = 0
    private var trailCount = 0
    private var sinceTrail = 0.0
    /// The delay in samples: a quarter of the main tone's period, frame by frame.
    private var delay = 12.0
    private var drift: Double
    private var angle: Double
    private let spin: Double
    /// Per-axis gains: the figure is measured along its diagonals (where a delay plot's shape lies) and each is
    /// scaled to fill the figure, within limits, so a quiet passage still shows a shape.
    private var gainU = 2.0
    private var gainV = 2.0
    /// 0 playing, 1 settled into the resting ring.
    private var quiet = 1.0
    private var level = 0.0
    private var pulse = 0.0
    private var calm = 0.0
    /// A drop's bloom of light, 1 on the drop, fading.
    private var bloom = 0.0
    private let tint: Int
    /// Ribbon outlines, kept between frames.
    private var ribbon: [CGPoint] = []
    private var back: [CGPoint] = []

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        spin = random.chance(0.5) ? 1 : -1
        angle = random.range(0, 2 * .pi)
        drift = random.range(0, 2 * .pi)
        tint = random.int(4)
        updateTrace()
    }

    var glow: Double { 1 }

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let scope = input.scope
        var mean = 0.0, energy = 0.0
        for i in samples.indices {
            let s = i < scope.count && scope[i].isFinite ? Double(min(max(scope[i], -1), 1)) : 0
            samples[i] = s
            mean += s
        }
        mean /= Double(samples.count)
        for i in samples.indices {
            samples[i] -= mean
            energy += samples[i] * samples[i]
        }
        let rms = (energy / Double(samples.count)).squareRoot()

        level += (Double(input.level) - level) * (1 - exp(-dt / 0.15))
        pulse = Double(input.pulse)
        calm += (Double(input.breakdown) - calm) * (1 - exp(-dt / 0.5))
        bloom = input.drop ? 1 : bloom * exp(-dt / 0.7)
        let sounding = !input.isSilent && rms > 0.004
        quiet += ((sounding ? 0 : 1) - quiet) * (1 - exp(-dt / 0.09))

        // The delay: where this frame's waveform first stops resembling itself (a quarter of its period), so its main
        // tone draws round. Each frame takes its own (frames are separate glimpses of the sound: a kick's frame and
        // the quiet one after it want different delays), and it drifts a little either side so the knots breathe.
        if sounding {
            delay = Double(firstZeroLag())
            drift += dt * (0.35 + 0.25 * level) * (1 - 0.6 * calm)
        }
        smooth()
        // Turns slowly, slower still in a breakdown, and rests in silence.
        angle += dt * spin * (0.12 + 0.3 * level) * (1 - 0.65 * calm) * (1 - quiet)

        updateTrace(dt: dt)

        // The afterglow: a trace kept 30 times a second, longer through a breakdown.
        sinceTrail += dt
        if sinceTrail >= 1.0 / 30 {
            sinceTrail = 0
            trailHead = (trailHead + 1) % Self.maxTrail
            let start = trailHead * Self.resolution
            for k in trace.indices { trails[start + k] = trace[k] }
            let wanted = Int((3.5 + 3.5 * calm).rounded())
            trailCount = min(trailCount + 1, wanted)
        }
    }

    /// The first lag (2...20 samples) at which the waveform's autocorrelation falls to zero.
    private func firstZeroLag() -> Int {
        let n = samples.count
        for lag in 2...20 {
            var sum = 0.0
            for i in lag..<n { sum += samples[i] * samples[i - lag] }
            if sum <= 0 { return lag }
        }
        return 20
    }

    /// Softens the waveform with a Gaussian scaled to the delay (a tenth of the main tone's period): the tone keeps its
    /// shape while the hiss and hats, which would only scribble over the loops, fall away.
    private func smooth() {
        let sigma = min(max(delay * 0.4, 1.3), 5)
        let reach = min(Int((sigma * 2).rounded(.up)), weights.count - 1)
        for k in 0...reach { weights[k] = exp(-Double(k * k) / (2 * sigma * sigma)) }
        let n = samples.count
        for i in 0..<n { raw[i] = samples[i] }
        for i in 0..<n {
            var sum = raw[i] * weights[0], total = weights[0]
            for k in 1...reach {
                let w = weights[k]
                sum += (raw[max(i - k, 0)] + raw[min(i + k, n - 1)]) * w
                total += 2 * w
            }
            samples[i] = sum / total
        }
    }

    /// The waveform at a fractional sample position, Catmull-Rom between samples.
    private func sample(at t: Double) -> Double {
        let n = samples.count
        let x = min(max(t, 0), Double(n - 1))
        let i = min(Int(x), n - 2)
        let f = x - Double(i)
        let p0 = samples[max(i - 1, 0)], p1 = samples[i], p2 = samples[i + 1], p3 = samples[min(i + 2, n - 1)]
        return p1 + 0.5 * f * (p2 - p0 + f * (2 * p0 - 5 * p1 + 4 * p2 - p3 + f * (3 * (p1 - p2) + p3 - p0)))
    }

    private func updateTrace(dt: Double = 0) {
        let n = Self.resolution
        let d = min(max(delay * (1 + 0.22 * sin(drift)), 2), 24)
        let last = Double(samples.count - 1)
        // The plot measured along its diagonals, where a delay plot's shape lies (the sample and the one before it
        // are alike, so the figure leans along x = y).
        var sumU = 0.0, sumV = 0.0
        for k in 0..<n {
            let t = d + (last - d) * Double(k) / Double(n - 1)
            let x = sample(at: t), y = sample(at: t - d)
            us[k] = x + y
            vs[k] = x - y
            sumU += us[k] * us[k]
            sumV += vs[k] * vs[k]
        }
        let rmsU = (sumU / Double(n)).squareRoot(), rmsV = (sumV / Double(n)).squareRoot()
        // Each diagonal is scaled to fill the figure (a tone comes out round), the narrow one by no more than three
        // times the wide one's gain, and quiet sound by no more than so much.
        let targetU = 0.45 / max(rmsU, 0.035)
        let targetV = 0.45 / max(rmsV, 0.035, rmsU * 0.33)
        if dt > 0, quiet < 0.5 {
            gainU += (targetU - gainU) * (1 - exp(-dt / (targetU < gainU ? 0.04 : 0.1)))
            gainV += (targetV - gainV) * (1 - exp(-dt / (targetV < gainV ? 0.04 : 0.1)))
        }
        let ca = cos(angle), sa = sin(angle)
        let q = quiet * quiet * (3 - 2 * quiet)
        for k in 0..<n {
            var u = us[k] * gainU, v = vs[k] * gainV
            // Soft limit, so a stray peak bends in rather than reaching the corners.
            let r = (u * u + v * v).squareRoot()
            if r > 0.8 {
                let limited = 0.8 + 0.25 * tanh((r - 0.8) / 0.25)
                u *= limited / r
                v *= limited / r
            }
            // Settling: the trace gathers into the resting ring.
            let a = 2 * Double.pi * Double(k) / Double(n - 1)
            u += (Self.restRadius * cos(a) - u) * q
            v += (Self.restRadius * sin(a) - v) * q
            trace[k] = CGPoint(x: u * ca - v * sa, y: u * sa + v * ca)
        }
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let unit = min(size.width, size.height) / 92
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let sounding = 1 - quiet
        let radius = unit * CGFloat(34 * (0.92 + 0.08 * pulse + 0.06 * bloom))

        // A soft light behind the figure: the drop's bloom, and a breath on each kick (dark artwork only).
        if !style.isLight {
            let light = style.glow.mixed(with: .white, 0.3)
            let alpha = sounding * 0.3 * pulse + 0.75 * bloom
            if alpha > 0.04 {
                ctx.fillGlow(at: c, radius: radius * CGFloat(1 + 0.4 * bloom), color: light, alpha: alpha)
            }
        }

        // The afterglow, oldest and faintest first.
        let trailColour = style.isLight ? style.spark(tint).scaled(0.7) : style.spark(tint).mixed(with: style.ink, 0.25)
        if trailCount > 0 {
            for age in stride(from: trailCount, through: 1, by: -1) {
                let index = (trailHead - age + 1 + Self.maxTrail * 2) % Self.maxTrail
                let fade = 1 - Double(age - 1) / Double(trailCount)
                // Many faint traces through a breakdown, a few brighter ones otherwise.
                let strength = (0.08 + 0.4 * fade * fade) * (1 - 0.45 * calm)
                ctx.setFill(trailColour, strength * (0.35 + 0.65 * sounding))
                let start = index * Self.resolution
                addRibbon(trails[start..<(start + Self.resolution)], in: ctx, centre: c, radius: radius,
                          width: unit * 1.1, every: 3)
                ctx.fillPath()
            }
        }

        // The trace itself, bolder on a kick, tapering and fading back from the beam like a phosphor's glow.
        let width = unit * CGFloat(1.5 + 0.7 * pulse * sounding + 0.8 * bloom)
        let sections = 5
        let strength = 0.55 + 0.4 * sounding
        for j in 0..<sections {
            let from = j * (Self.resolution - 1) / sections, to = (j + 1) * (Self.resolution - 1) / sections
            let t = Double(j + 1) / Double(sections)
            // From the afterglow's colour at the tail to the ink at the beam.
            ctx.setFill(trailColour.mixed(with: style.ink, 0.35 + 0.65 * t), strength * (1 - (1 - t) * 0.6 * sounding))
            addRibbon(trace[from...to], in: ctx, centre: c, radius: radius, width: width, every: 1)
            ctx.fillPath()
        }

        // The beam: a bright dot at the newest end.
        if let head = trace.last {
            let p = CGPoint(x: c.x + head.x * radius, y: c.y + head.y * radius)
            let r = unit * CGFloat(1.5 + 0.6 * pulse * sounding)
            ctx.setFill(style.isLight ? style.ink : style.ink.mixed(with: .white, 0.5), 0.95)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
    }

    /// A trace as a filled ribbon `width` across: every `step`th point offset either side along the curve's normal.
    /// Filling it costs a fraction of stroking the curve (a tangle's stroke is dear), and a smooth trace has no bends
    /// tight enough for the ribbon to fold.
    private func addRibbon(_ points: ArraySlice<CGPoint>, in ctx: CGContext, centre c: CGPoint, radius: CGFloat,
                           width: CGFloat, every step: Int) {
        let first = points.startIndex, last = points.endIndex - 1
        guard last - first > 1 else { return }
        let half = width / 2
        ribbon.removeAll(keepingCapacity: true)
        back.removeAll(keepingCapacity: true)
        var i = first
        while true {
            let a = points[max(i - step, first)], b = points[min(i + step, last)], p = points[i]
            var nx = -(b.y - a.y), ny = b.x - a.x
            let length = (nx * nx + ny * ny).squareRoot()
            if length > 0 {
                nx *= half / (length * radius)
                ny *= half / (length * radius)
            }
            ribbon.append(CGPoint(x: c.x + (p.x + nx) * radius, y: c.y + (p.y + ny) * radius))
            back.append(CGPoint(x: c.x + (p.x - nx) * radius, y: c.y + (p.y - ny) * radius))
            if i == last { break }
            i = min(i + step, last)
        }
        ribbon.append(contentsOf: back.reversed())
        ctx.addLines(between: ribbon)
        ctx.closePath()
    }
}
