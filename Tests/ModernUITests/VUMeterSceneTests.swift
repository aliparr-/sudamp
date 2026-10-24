// SPDX-License-Identifier: GPL-3.0-or-later
// The VU Meters scene's needles move as a VU meter's do: a step rises to 99% in about 300 ms with an overshoot of
// 1–2%, whatever the frame rate, and in silence the needle falls back to its stop well within half a second.
import Testing
@testable import ModernUI

@Suite struct VUMeterSceneTests {
    @Test(arguments: [1.0 / 60, 1.0 / 30, 1.0 / 10])
    func needleHasVUBallistics(dt: Double) {
        var needle = VUMeterScene.Needle()
        var t = 0.0, peak = 0.0
        var reached: Double?
        while t < 1.5 {
            needle.step(toward: 0.5, dt: dt)
            t += dt
            peak = max(peak, needle.x)
            if reached == nil, needle.x >= 0.495 { reached = t }
        }
        let overshoot = peak / 0.5 - 1
        #expect(overshoot > 0.005 && overshoot < 0.025)
        #expect((reached ?? 10) > 0.2 && (reached ?? 10) <= 0.32)
        #expect(abs(needle.x - 0.5) < 0.001)

        // Silence: back against the stop, and still.
        var fall = 0.0
        while fall < 0.5 {
            needle.step(toward: -0.06, dt: dt)
            fall += dt
        }
        #expect(needle.x <= 0)
        #expect(abs(needle.velocity) < 0.05)
    }

    /// The scale is linear in voltage, as a VU meter's is: 0 VU sits about 71% of the way to +3.
    @Test func zeroSitsWhereAVUMetersDoes() {
        #expect(abs(VUMeterScene.Needle.zero - 0.708) < 0.001)
    }
}
