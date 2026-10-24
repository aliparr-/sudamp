// SPDX-License-Identifier: GPL-3.0-or-later
// Heartbeat: a patient monitor that follows the beat. An ECG trace sweeps across a faint grid from left to right,
// erasing just ahead of its bright write head while the older trace fades, and draws a heartbeat on every kick: a
// small P wave just before the beat (the beat clock knows when it's due), the sharp QRS spike on it, as tall as the
// bass is strong, and a rounded T wave after. Treble puts a little jitter on the baseline. The sweep crosses the
// screen in about three beats, a BPM readout in pixel digits shows the clock's tempo, and a heart beside it pulses on
// every beat. Through a breakdown the heart keeps the clock's time with shallower beats; the drop fires a huge spike,
// the screen flashes and the heart jumps. In silence the trace flatlines and the readout shows dashes (calmly: no
// alarm). A seed picks the trace's colour and whether the grid is ruled lines or dots.

import CoreGraphics
import Foundation

nonisolated final class HeartbeatScene: VisualizerScene {
    /// A point of the trace: across the screen in points (0 at its left edge), up from the baseline in points, and
    /// when it was written.
    private struct Sample {
        var x: CGFloat
        var y: CGFloat
        var time: Double
    }

    /// A heartbeat's QRS spike and T wave, from `start` (the spike's onset), `height` points tall.
    private struct Beat {
        var start: Double
        var height: Double
        /// Stretches the gap before the T wave and the wave itself with the beat's length, as a heart's does.
        var stretch: Double

        /// The spike's corners, seconds after its onset: the Q dip, the R peak, the S dip, back to the baseline.
        static let corners: [Double] = [0, 0.018, 0.042, 0.068, 0.092]

        func value(at t: Double) -> Double {
            let s = t - start
            guard s >= 0 else { return 0 }
            let c = Self.corners
            let q = -0.1 * height, r = height, sDip = -0.24 * height
            if s < c[1] { return q * s / c[1] }
            if s < c[2] { return q + (r - q) * (s - c[1]) / (c[2] - c[1]) }
            if s < c[3] { return r + (sDip - r) * (s - c[2]) / (c[3] - c[2]) }
            if s < c[4] { return sDip * (1 - (s - c[3]) / (c[4] - c[3])) }
            // The T wave: a gentle hump after a short flat stretch.
            let from = 0.15 * stretch, length = 0.17 * stretch
            guard s > from, s < from + length else { return 0 }
            let bump = sin(Double.pi * (s - from) / length)
            return min(3.8, 1 + 0.12 * height) * bump * bump
        }

        func isOver(at t: Double) -> Bool { t - start > 0.4 * stretch + 0.1 }
    }

    /// The screen, in the 92-point square: where the trace runs, its baseline, and the gap the head erases ahead.
    private static let left: CGFloat = 8
    private static let width: CGFloat = 76
    private static let baseline: CGFloat = 63
    private static let gap: CGFloat = 7
    /// Points between samples of the trace (the spike's corners are written exactly as well).
    private static let step: CGFloat = 0.7
    private static let pWave = (lead: 0.16, length: 0.08, height: 2.6)

    private var random: SceneRandom
    private let traceColour: Int
    private let dottedGrid: Bool

    private var time = 0.0
    /// The write head, in points from the screen's left edge, and its speed (set at the start of each sweep).
    private var head: CGFloat
    private var speed: CGFloat = 52
    private var sweepTime = 1.45
    /// This sweep's trace, and what's left of the last one ahead of the head.
    private var current: [Sample] = []
    private var previous: [Sample] = []
    private var beats: [Beat] = []
    private var pWaves: [Double] = []
    private var jitter = 0.0

    private var activity = 0.0
    private var treble = 0.0
    private var lastGroove = 0.0
    private var sinceBeat = 10.0
    /// A clock beat with no kick on it yet: seconds left before it draws a shallow beat of its own.
    private var pending: Double?
    private var tempo = 0.5
    /// The tempo averaged over a few beats, and the BPM on show (it changes on a beat, and only by a clear step, as a
    /// monitor's readout does); nil shows dashes.
    private var averageTempo = 0.5
    private var bpm: Int?
    /// The heart's pulse (1 on a beat, more at the drop), its jump at the drop, and the screen's flash.
    private var heart = 0.0
    private var jump = 0.0
    private var flash = 0.0

    /// The grid's squares, worked out once per size.
    private var grid: (size: CGSize, rects: [CGRect])?

    init(seed: UInt64) {
        random = SceneRandom(seed: seed)
        traceColour = random.int(2)
        dottedGrid = random.chance(0.5)
        head = CGFloat(random.range(0.25, 0.75)) * Self.width
        // A fresh monitor shows a flat line all the way across (but for the gap ahead of the head).
        var x: CGFloat = 0
        while x < Self.width {
            if x < head {
                current.append(Sample(x: x, y: 0, time: -Double((head - x) / speed)))
            } else if x > head + Self.gap {
                previous.append(Sample(x: x, y: 0, time: -Double((Self.width - x + head) / speed)))
            }
            x += Self.step * 2
        }
    }

    var glow: Double { 1 }

    // MARK: Update

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let sounding = !input.isSilent
        activity += ((sounding ? 1 : 0) - activity) * (1 - exp(-dt / (sounding ? 0.1 : 0.08)))
        treble += (Double(input.treble) - treble) * (1 - exp(-dt / 0.1))
        tempo = input.beatInterval
        averageTempo += (tempo - averageTempo) * (input.beats < 4 ? 1 : 1 - exp(-dt / 2))
        if !sounding || input.beats < 2 { bpm = nil }
        sinceBeat += dt
        heart *= exp(-dt / 0.16)
        jump *= exp(-dt / 0.22)
        flash *= exp(-dt / 0.2)

        let groove = input.groove
        let downbeat = groove < lastGroove - 0.5
        let pAt = 1 - Self.pWave.lead / max(tempo, 0.3)
        let pDue = lastGroove < pAt && groove >= pAt
        lastGroove = groove
        let breakdown = Double(input.breakdown)
        if sounding {
            // The P wave goes up just before the beat the clock expects.
            if pDue { pWaves.append(time + dt) }
            // A kick on the beat draws a heartbeat as tall as the bass; through a breakdown (whose bassline hits
            // between the beats) or a stretch with no kicks, the clock's beats draw shallower ones.
            let onBeat = groove < 0.15 || groove > 0.85
            if input.drop {
                // As tall as the screen allows: up to just under the readout.
                let height = 33.0
                if let last = beats.last, time + dt - last.start < 0.04 {
                    beats[beats.count - 1].height = height
                } else {
                    fire(height: height, at: time + dt)
                }
                heart = 1.8
                jump = 1
                flash = 1
                pending = nil
            } else if input.beat, onBeat, breakdown < 0.5, sinceBeat > 0.25 {
                let strength = min(max((Double(input.bass) - 0.35) / 0.55, 0), 1)
                fire(height: 12 + 10 * strength, at: time + dt)
                pending = nil
            }
            if downbeat, sinceBeat > 0.25 { pending = 0.09 }
            if let left = pending {
                if left <= dt {
                    pending = nil
                    if sinceBeat > 0.25 { fire(height: 7 + 4 * (1 - breakdown), at: time + dt) }
                } else {
                    pending = left - dt
                }
            }
        } else {
            pending = nil
        }

        write(until: time + dt, sounding: sounding)
        time += dt
        beats.removeAll { $0.isOver(at: time) }
        pWaves.removeAll { time - $0 > Self.pWave.length }

        // In silence the trace settles to a flat line within a few tenths of a second.
        if !sounding {
            let settle = CGFloat(exp(-dt / 0.07))
            for i in current.indices { current[i].y *= settle }
            for i in previous.indices { previous[i].y *= settle }
        }
    }

    private func fire(height: Double, at start: Double) {
        let stretch = min(max(tempo / 0.5, 0.75), 1.3)
        beats.append(Beat(start: start, height: height, stretch: stretch))
        sinceBeat = 0
        heart = max(heart, min(1, height / 20))
        let measured = 60 / max(averageTempo, 0.3)
        if bpm == nil || abs(measured - Double(bpm ?? 0)) > 0.8 { bpm = Int(measured.rounded()) }
    }

    /// Moves the head on to `end`, writing the trace as it goes (and erasing ahead of it).
    private func write(until end: Double, sounding: Bool) {
        var t = time
        while t < end - 1e-9 {
            // The next sample: a step along, a spike's corner, the edge of the screen, or the end of the frame.
            var next = min(end, t + Double(Self.step / speed), t + Double((Self.width - head) / speed))
            for beat in beats {
                for c in Beat.corners where beat.start + c > t + 1e-6 && beat.start + c < next {
                    next = beat.start + c
                }
            }
            head += CGFloat(next - t) * speed
            t = next
            // Treble jitter on the baseline, smoothed a little so it reads as noise, not spikes.
            jitter = jitter * 0.5 + random.range(-1, 1) * 0.5
            var y = sounding ? jitter * (0.15 + 1.1 * treble) : 0
            for beat in beats { y += beat.value(at: t) }
            for p in pWaves where t > p && t < p + Self.pWave.length {
                let bump = sin(Double.pi * (t - p) / Self.pWave.length)
                y += Self.pWave.height * bump * bump
            }
            if head >= Self.width - 1e-6 {
                // Round again: this sweep becomes the old trace, and the speed is set for the next from the tempo
                // (two to four beats across, about a second and a half).
                current.append(Sample(x: Self.width, y: CGFloat(y), time: t))
                previous = current
                current.removeAll(keepingCapacity: true)
                head = 0
                let perSweep = min(max((1.5 / max(tempo, 0.3)).rounded(), 2), 4)
                sweepTime = perSweep * max(tempo, 0.3)
                speed = Self.width / CGFloat(sweepTime)
            }
            current.append(Sample(x: head, y: CGFloat(y), time: t))
        }
        // The erase gap just ahead of the head.
        let erase = head + Self.gap
        var cut = 0
        while cut < previous.count, previous[cut].x < erase { cut += 1 }
        if cut > 0 { previous.removeFirst(cut) }
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let u = size.width / 92
        let light = style.isLight
        let traceInk = light ? style.ink : style.spark(traceColour).mixed(with: style.ink, 0.35)
        drawGrid(ctx, u: u, style: style)

        // The drop's flash across the whole screen.
        if flash > 0.01 {
            ctx.setFill(light ? style.accent : style.glow.mixed(with: .white, 0.5), (light ? 0.2 : 0.3) * flash)
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        // The trace: in runs, each as bright as it is fresh, the old sweep fading out ahead of the head.
        ctx.saveGState()
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setLineWidth(1.5 * u)
        func point(_ s: Sample) -> CGPoint { CGPoint(x: (Self.left + s.x) * u, y: (Self.baseline - s.y) * u) }
        for run in [previous, current] where run.count > 1 {
            var start = 0
            while start < run.count - 1 {
                var end = start + 1
                while end < run.count - 1, run[end].x - run[start].x < 6 { end += 1 }
                let age = (time - run[end].time) / sweepTime
                let alpha = max(0.18, 1 - 0.85 * age)
                let chunk = CGMutablePath()
                chunk.move(to: point(run[start]))
                for i in (start + 1)...end { chunk.addLine(to: point(run[i])) }
                ctx.addPath(chunk)
                ctx.setStroke(traceInk, alpha)
                ctx.strokePath()
                start = end
            }
        }
        ctx.restoreGState()

        // The write head: a bright spot.
        if let last = current.last ?? previous.last {
            let p = point(last)
            if !light { ctx.fillGlow(at: p, radius: 6 * u, color: traceInk, alpha: 0.55) }
            let r = 1.7 * u
            ctx.setFill(light ? style.ink : traceInk.mixed(with: .white, 0.6))
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }

        drawReadout(ctx, u: u, style: style)
    }

    private func drawGrid(_ ctx: CGContext, u: CGFloat, style: SceneStyle) {
        let alpha = (style.isLight ? 0.1 : 0.085) * (dottedGrid ? 2.4 : 1)
        if grid?.size.width != u * 92 { grid = (CGSize(width: u * 92, height: u * 92), gridRects(u: u)) }
        ctx.setFill(style.ink, alpha)
        ctx.fill(grid?.rects ?? [])
    }

    /// The grid as whole-point squares: ruled lines, or dots at the crossings and halfway down.
    private func gridRects(u: CGFloat) -> [CGRect] {
        let top: CGFloat = 34, bottom: CGFloat = 82, spacing: CGFloat = 9.5
        var rects: [CGRect] = []
        if dottedGrid {
            var y = top
            while y <= bottom + 0.1 {
                var x = Self.left
                while x <= Self.left + Self.width + 0.1 {
                    rects.append(CGRect(x: (x * u).rounded() - u * 0.5, y: (y * u).rounded() - u * 0.5, width: u,
                                        height: u))
                    x += spacing
                }
                y += spacing / 2
            }
        } else {
            var y = top
            while y <= bottom + 0.1 {
                rects.append(CGRect(x: Self.left * u, y: (y * u).rounded(), width: Self.width * u, height: u))
                y += spacing
            }
            var x = Self.left
            while x <= Self.left + Self.width + 0.1 {
                rects.append(CGRect(x: (x * u).rounded(), y: top * u, width: u, height: (bottom - top) * u))
                x += spacing
            }
        }
        return rects
    }

    /// The heart and the BPM, top right (clear of the window's buttons at the top left).
    private func drawReadout(_ ctx: CGContext, u: CGFloat, style: SceneStyle) {
        let light = style.isLight
        let text = bpm.map { String($0) } ?? "---"
        let pixel = 2 * u
        let digits = CGFloat(PixelFont.width(text)) * pixel
        let right = 82 * u
        ctx.setFill(style.ink, 0.95)
        PixelFont.fill(text, in: ctx, at: CGPoint(x: (right - digits).rounded(), y: (13 * u).rounded()), pixel: pixel)
        ctx.setFill(style.ink, 0.6)
        PixelFont.fill("BPM", in: ctx, at: CGPoint(x: (right - CGFloat(PixelFont.width("BPM")) * u).rounded(),
                                                   y: (25 * u).rounded()), pixel: u)

        // The heart: it beats with the trace, jumps at the drop, and rests calmly in silence.
        let scale = 1 + 0.3 * min(heart, 1) + 0.25 * max(heart - 1, 0)
        let centre = CGPoint(x: (right - 22 * u - 9 * u), y: (18 - 4 * jump) * u)
        let colour = light ? style.accent.mixed(with: style.ink, 0.25) : style.accent.mixed(with: .white, 0.15)
        if !light, heart > 0.05 {
            ctx.fillGlow(at: centre, radius: 10 * u * CGFloat(scale), color: colour, alpha: 0.45 * min(heart, 1))
        }
        addHeart(ctx, centre: centre, size: 11 * u * CGFloat(scale))
        ctx.setFill(colour, 0.6 + 0.4 * activity)
        ctx.fillPath()
    }

    /// A heart `size` points across, centred on `centre`, added to the context's path.
    private func addHeart(_ ctx: CGContext, centre c: CGPoint, size: CGFloat) {
        let w = size / 2, h = size * 0.9 / 2
        let top = c.y - h * 0.55
        ctx.move(to: CGPoint(x: c.x, y: c.y + h))
        ctx.addCurve(to: CGPoint(x: c.x - w, y: top), control1: CGPoint(x: c.x - w * 0.5, y: c.y + h * 0.55),
                     control2: CGPoint(x: c.x - w, y: c.y + h * 0.1))
        for side in [-1.0, 1.0] as [CGFloat] {
            ctx.addArc(center: CGPoint(x: c.x + side * w / 2, y: top), radius: w / 2, startAngle: .pi, endAngle: 0,
                       clockwise: false)
        }
        ctx.addCurve(to: CGPoint(x: c.x, y: c.y + h), control1: CGPoint(x: c.x + w, y: c.y + h * 0.1),
                     control2: CGPoint(x: c.x + w * 0.5, y: c.y + h * 0.55))
        ctx.closePath()
    }
}
