// SPDX-License-Identifier: GPL-3.0-or-later
// Pendulums: the pendulum-wave toy. A row of pendulums hangs from a bar across the top, seen from the front and a
// little above, so a bob swinging towards the viewer drops lower and grows. Their lengths are graded (the longest, with
// the bass, at the left), so each swings a little faster than the one before and together they drift through
// travelling waves, snakes and back into step. Each pendulum hears its own band of the spectrum: its level pumps the
// swing and lights the bob; every kick jolts the bar and nudges them all. Through a breakdown the wave unfolds calmly
// on its own; the drop throws them all high in unison, and they fan out into the wave again. In silence the swings
// die away quickly and they hang still in a neat row. A seed picks the order of the bobs' colours.

import CoreGraphics
import Foundation

nonisolated final class PendulumScene: VisualizerScene {
    private struct Pendulum {
        /// The swing angle, and its rate of change over the pendulum's own angular frequency (so the two together
        /// trace a circle and the swing can be stepped exactly, at any frame rate).
        var angle = 0.0
        var turn = 0.0
        /// Radians a second.
        var omega: Double
        /// How long it hangs, in points (at 92 across).
        var length: Double
        var x: Double
        /// Its band's level, smoothed: lights the bob.
        var level = 0.0
    }

    private static let count = 15
    /// The wave's whole cycle (seconds): pendulum i swings `first + i` times in it, so they all line up again.
    private static let cycle = 36.0
    private static let first = 20.0
    private static let barY = 13.0
    /// How far above the bobs the camera looks down (radians): a bob swinging towards the viewer drops lower.
    private static let tilt = 0.5

    private var pendulums: [Pendulum] = []
    private var energy = 0.0
    private var calm = 0.0
    private var pulse = 0.0
    /// The bar's jolt on a kick, in points, ringing down.
    private var jolt = 0.0
    private var joltSpeed = 0.0
    /// The drop: seconds left of gathering every pendulum into one big swing.
    private var gather = 0.0
    private var gatherPhase = 0.0
    private let hueShift: Int
    private var order = [Int](repeating: 0, count: count)

    init(seed: UInt64) {
        var random = SceneRandom(seed: seed)
        hueShift = random.int(4)
        let n = Self.count
        for i in 0..<n {
            let swings = Self.first + Double(n - 1 - i)
            let omega = 2 * .pi * swings / Self.cycle
            // Lengths graded as the swing times are (a pendulum's period goes as the root of its length), squeezed
            // into the space below the bar.
            let shortest = 2 * .pi * (Self.first + Double(n - 1)) / Self.cycle
            let ratio = pow(shortest / omega, 2) // 1 for the shortest, more for longer ones
            let maxRatio = pow((Self.first + Double(n - 1)) / Self.first, 2)
            let length = 40 + 18 * (ratio - 1) / (maxRatio - 1)
            let x = 15 + 62 * Double(i) / Double(n - 1)
            pendulums.append(Pendulum(omega: omega, length: length, x: x))
        }
    }

    var glow: Double { 0.8 }

    func update(_ input: VisualizerInput, dt rawDt: Double) {
        let dt = min(max(rawDt.isFinite ? rawDt : 0, 0), 0.25)
        let sounding = !input.isSilent
        energy += ((sounding ? 1 : 0) - energy) * (1 - exp(-dt / 0.08))
        calm += (Double(input.breakdown) - calm) * (1 - exp(-dt / 0.6))
        pulse = Double(input.pulse)

        // The bar jolts sideways on a kick, a stiff spring that rings down.
        if input.beat, sounding { joltSpeed += 26 }
        let steps = max(1, Int((dt / (1.0 / 120)).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            joltSpeed += (-jolt * 900 - joltSpeed * 28) * h
            jolt += joltSpeed * h
        }

        if input.drop {
            gather = 0.3
            // Where the middle pendulum is now, so the gathering doesn't throw them far.
            let mid = pendulums[Self.count / 2]
            gatherPhase = atan2(mid.angle, mid.turn)
        }

        let n = Self.count
        for i in 0..<n {
            var p = pendulums[i]
            let band = Double(input.band(at: Double(i) / Double(n - 1)))
            p.level += (band - p.level) * (1 - exp(-dt / (band > p.level ? 0.05 : 0.25)))

            // The swing, stepped exactly: (angle, turn) turns about the origin at the pendulum's frequency.
            let c = cos(p.omega * dt), s = sin(p.omega * dt)
            (p.angle, p.turn) = (p.angle * c + p.turn * s, p.turn * c - p.angle * s)

            // Each band pumps its own swing up towards what its level asks for; above that, the swing dies away
            // slowly while playing, and fast in silence. Through a breakdown they all keep an even swing, so the wave
            // shows on its own.
            let amplitude = (p.angle * p.angle + p.turn * p.turn).squareRoot()
            let wanted = (0.14 + 0.18 * min(max((p.level - 0.15) / 0.6, 0), 1)) * (1 - calm) + 0.28 * calm
            var next = amplitude
            if sounding {
                if wanted > amplitude {
                    next += (wanted - amplitude) * (1 - exp(-dt / 0.5))
                } else {
                    next = wanted + (amplitude - wanted) * exp(-dt / (1.2 + 2 * calm))
                }
                // A kick nudges them all a little higher (each keeping its place in the wave); through a breakdown
                // they're left to swing on their own.
                if input.beat { next += (0.04 + 0.03 * Double(input.bass)) * (1 - calm) }
            } else {
                next = amplitude * exp(-dt / 0.06)
            }
            if amplitude > 1e-9 {
                p.angle *= next / amplitude
                p.turn *= next / amplitude
            } else if sounding {
                // Still and starting: swing off from the middle of the bar's line, all together.
                p.turn = next
            }
            pendulums[i] = p
        }

        // The drop: they're gathered into one high swing, then let go to fan out again.
        if gather > 0 {
            let k = 1 - exp(-dt / 0.08)
            gatherPhase += dt * pendulums[n / 2].omega
            let big = 0.6
            for i in 0..<n {
                pendulums[i].angle += (big * sin(gatherPhase) - pendulums[i].angle) * k
                pendulums[i].turn += (big * cos(gatherPhase) - pendulums[i].turn) * k
            }
            gather -= dt
        }
    }

    /// How far below the bar a bob looks: its string seen from a little above, the swing towards the viewer showing as
    /// a drop (and the rise at either end of the swing as a little lift).
    private static func drop(_ p: Pendulum) -> Double {
        p.length * (cos(tilt) + 0.62 * sin(p.angle) - 0.25 * (1 - cos(p.angle)))
    }

    func draw(in ctx: CGContext, size: CGSize, style: SceneStyle) {
        let u = min(size.width, size.height) / 92
        let ox = (size.width - 92 * u) / 2, oy = (size.height - 92 * u) / 2
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + CGFloat(x) * u, y: oy + CGFloat(y) * u) }
        let barY = Self.barY
        let shift = jolt

        // Where each bob is: down the string, and towards or away from the viewer.
        let n = Self.count
        for i in 0..<n { order[i] = i }
        func depth(_ i: Int) -> Double { pendulums[i].angle }
        // Far bobs first, so near ones pass in front.
        for i in 1..<n {
            var j = i
            while j > 0, depth(order[j - 1]) > depth(order[j]) {
                order.swapAt(j - 1, j)
                j -= 1
            }
        }

        // The strings, in one stroke.
        ctx.setLineWidth(0.75 * u)
        ctx.setStroke(style.ink, 0.38)
        for p in pendulums {
            let ax = p.x + shift
            let by = barY + Self.drop(p)
            ctx.move(to: point(ax, barY))
            ctx.addLine(to: point(ax, by))
        }
        ctx.strokePath()

        // The bar, with a highlight along its top.
        let bar = CGRect(x: ox + CGFloat(9 + shift) * u, y: oy + CGFloat(barY - 2) * u, width: 74 * u, height: 3.4 * u)
        ctx.setFill(style.ink, 0.78)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1.7 * u, cornerHeight: 1.7 * u, transform: nil))
        ctx.fillPath()
        ctx.setFill(style.isLight ? style.ink.mixed(with: .white, 0.45) : .white, style.isLight ? 0.6 : 0.4)
        ctx.fill(CGRect(x: bar.minX + 1.7 * u, y: bar.minY + 0.5 * u, width: bar.width - 3.4 * u, height: 0.9 * u))

        // The bobs: a ball in its spark colour, lit by its band, with a glint.
        let glints = CGMutablePath()
        for i in order {
            let p = pendulums[i]
            let z = sin(p.angle)
            let by = barY + Self.drop(p)
            let c = point(p.x + shift, by)
            let r = CGFloat(2.25 * (1 + 0.22 * z)) * u
            let lit = min(max(p.level * 1.3 * energy, 0), 1)
            let hue = Double(i) / Double(n - 1) * 3 + Double(hueShift)
            let base = style.spark(Int(hue)).mixed(with: style.spark(Int(hue) + 1), hue - hue.rounded(.down))
            let colour: RGB
            if style.isLight {
                colour = base.scaled(0.62 + 0.15 * lit).mixed(with: style.ink, 0.25)
            } else {
                colour = base.mixed(with: .white, 0.04 + 0.4 * lit + 0.2 * pulse * energy)
            }
            ctx.setFill(colour, style.isLight ? 0.95 : 0.7 + 0.3 * lit)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let g = r * 0.38
            glints.addEllipse(in: CGRect(x: c.x - r * 0.42 - g, y: c.y - r * 0.42 - g, width: g * 2, height: g * 2))
        }
        ctx.addPath(glints)
        ctx.setFill(style.isLight ? style.mid.mixed(with: .white, 0.5) : .white, style.isLight ? 0.5 : 0.6)
        ctx.fillPath()
    }
}
