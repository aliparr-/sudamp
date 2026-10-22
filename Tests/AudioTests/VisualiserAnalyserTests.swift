// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Audio

@Suite struct VisualiserAnalyserTests {
    static let frameNanos: UInt64 = 33_333_333

    /// Renders `frames` of `signal` through the bridge's C render body (fills the visualiser ring).
    static func feed(_ bridge: RenderBridge, frames: Int, chunk: Int = 512) {
        var l = [Float](repeating: 0, count: chunk), r = [Float](repeating: 0, count: chunk)
        var done = 0
        while done < frames {
            let n = min(chunk, frames - done)
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    _ = bridge.process(left: lb.baseAddress!, right: rb.baseAddress!, frames: n)
                }
            }
            done += n
        }
    }

    static func sine(_ f: Double, amplitude: Float = 0.5, count: Int = VisualiserAnalyser.windowSize) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * Double.pi * f * Double($0) / 48_000)) }
    }

    @Test func bandsAreLogSpaced40HzTo16kHz() {
        let edges = VisualiserAnalyser.bandEdges
        #expect(edges.count == 20)
        #expect(abs(edges[0] - 40) < 1e-9 && abs(edges[19] - 16_000) < 1e-6)
        let ratios = zip(edges.dropFirst(), edges).map { $0 / $1 }
        #expect(ratios.allSatisfy { abs($0 - ratios[0]) < 1e-9 })
        #expect(VisualiserAnalyser.bar(containing: 40) == 0)
        #expect(VisualiserAnalyser.bar(containing: 15_999) == 18)
        #expect(VisualiserAnalyser.bar(containing: 20_000) == nil)
        // Every band reads something: narrow low bands without an FFT bin interpolate.
        #expect(VisualiserAnalyser.bandLayout().count == 19)
    }

    @Test func sineAt1kHzPeaksInItsBar() throws {
        let analyser = VisualiserAnalyser(bridge: nil)
        let frame = Self.sine(1000).withUnsafeBufferPointer { analyser.analyse(samples: $0, nowNanos: Self.frameNanos) }
        let expected = try #require(VisualiserAnalyser.bar(containing: 1000))
        let bars = frame.bars
        #expect(bars.firstIndex(of: bars.max()!) == expected)
        // Away from the tone the spectrum is far down (Hann side lobes).
        #expect(bars[expected] > 0.8)
        #expect(bars[2] < 0.05 && bars[18] < 0.05)
    }

    /// From 250 Hz up a bar is wider than the 46.9 Hz FFT bins; below that a 1024-sample window cannot tell the
    /// lowest bars apart (a 60 Hz tone lights the 40–55 Hz and 55–75 Hz bars almost equally).
    @Test(arguments: [250.0, 600, 3000, 8000, 12_000])
    func sinesPeakInTheirBars(frequency: Double) throws {
        let analyser = VisualiserAnalyser(bridge: nil)
        let frame = Self.sine(frequency, amplitude: 0.05).withUnsafeBufferPointer {
            analyser.analyse(samples: $0, nowNanos: Self.frameNanos)
        }
        let bars = frame.bars
        #expect(bars.firstIndex(of: bars.max()!) == VisualiserAnalyser.bar(containing: frequency))
    }

    @Test func levelIsCalibratedToSinePower() throws {
        // A -20 dBFS sine wholly inside a band reads -20 dB → (−20 − floor) / (ceiling − floor).
        let analyser = VisualiserAnalyser(bridge: nil)
        let frame = Self.sine(1100, amplitude: 0.1).withUnsafeBufferPointer {
            analyser.analyse(samples: $0, nowNanos: Self.frameNanos)
        }
        let s = analyser.settings
        let expected = (-20 - s.floorDB) / (s.ceilingDB - s.floorDB)
        #expect(abs(frame.bar(VisualiserAnalyser.bar(containing: 1100)!) - expected) < 0.01)
    }

    @Test func silenceGivesZeros() {
        let analyser = VisualiserAnalyser(bridge: nil)
        let zeros = [Float](repeating: 0, count: 1024)
        let frame = zeros.withUnsafeBufferPointer { analyser.analyse(samples: $0, nowNanos: Self.frameNanos) }
        #expect(frame.isSilent)
        #expect(frame.bars.allSatisfy { $0 == 0 } && frame.peaks.allSatisfy { $0 == 0 })
        #expect(frame.scope.allSatisfy { $0 == 0 })
        #expect((0..<19).allSatisfy { frame.barHeight($0) == 0 && frame.peakHeight($0) == 0 })
        #expect((0..<76).allSatisfy { frame.scopeRow($0) == 8 })
    }

    @Test func scopeFollowsTheWaveform() {
        // One cycle across the window: the scope shows exactly that cycle, sampled every 1024/76 samples.
        let analyser = VisualiserAnalyser(bridge: nil)
        let input = Self.sine(48_000.0 / 1024, amplitude: 0.5)
        let frame = input.withUnsafeBufferPointer { analyser.analyse(samples: $0, nowNanos: Self.frameNanos) }
        #expect(frame.scope.count == 76)
        for x in 0..<76 { #expect(frame.scope(x) == input[x * 1024 / 76]) }
        #expect(frame.scope[0...37].allSatisfy { $0 >= 0 } && frame.scope[39...].allSatisfy { $0 <= 0 })
        #expect(frame.scopeRow(19) == 4) // +0.5 at a quarter cycle → row (1 − 0.5) / 2 · 15 ≈ 4
        let loud = [Float](repeating: 3, count: 1024)
        let clipped = loud.withUnsafeBufferPointer { analyser.analyse(samples: $0, nowNanos: 2 * Self.frameNanos) }
        #expect(clipped.scope.allSatisfy { $0 == 1 } && clipped.scopeRow(0) == 0)
    }

    @Test func barsFallAndPeaksHoldThenFall() {
        let analyser = VisualiserAnalyser(bridge: nil)
        let tone = Self.sine(1000)
        let zeros = [Float](repeating: 0, count: 1024)
        let bar = VisualiserAnalyser.bar(containing: 1000)!
        var t = Self.frameNanos
        let loud = tone.withUnsafeBufferPointer { analyser.analyse(samples: $0, nowNanos: t) }
        var previous = loud
        var frames: [VisualiserFrame] = []
        for _ in 0..<60 {
            t += Self.frameNanos
            let f = zeros.withUnsafeBufferPointer { analyser.analyse(samples: $0, nowNanos: t) }
            #expect(f.bar(bar) <= previous.bar(bar))
            #expect(f.peak(bar) >= f.bar(bar))
            frames.append(f)
            previous = f
        }
        let step = analyser.settings.barFalloffPerSecond / 30
        #expect(abs((loud.bar(bar) - frames[0].bar(bar)) - step) < 1e-3)
        #expect(frames[5].peak(bar) > frames[5].bar(bar)) // the peak lingers above the falling bar
        #expect(frames.last!.isSilent) // two seconds later everything is down
    }

    @Test func readsTheRingWithLatencyLag() throws {
        let bridge = RenderBridge()
        bridge.setTestSignal(.sine(frequency: 1000, amplitude: 0.5))
        bridge.setLatency(seconds: 0.012)
        #expect(bridge.latencyFrames == 576)
        Self.feed(bridge, frames: 4096)
        let analyser = VisualiserAnalyser(bridge: bridge)
        let frame = analyser.analyse(nowNanos: Self.frameNanos)
        #expect(frame.framesWritten == 4096)
        let bars = frame.bars
        #expect(bars.firstIndex(of: bars.max()!) == VisualiserAnalyser.bar(containing: 1000))
    }

    @Test func lagSelectsTheAudibleWindow() {
        // Counter signal: the window must end exactly latencyFrames before the write position.
        let bridge = RenderBridge()
        bridge.setTestSignal(.counter)
        bridge.setLatency(seconds: 0.010) // 480 frames
        Self.feed(bridge, frames: 3000)
        var window = [Float](repeating: -1, count: 1024)
        let ok = window.withUnsafeMutableBufferPointer { bridge.copyNewest(into: $0, lagFrames: bridge.latencyFrames) }
        #expect(ok && window.first == Float(3000 - 480 - 1024) && window.last == Float(3000 - 480 - 1))
        let analyser = VisualiserAnalyser(bridge: bridge)
        let frame = analyser.analyse(nowNanos: Self.frameNanos)
        #expect(frame.scope(0) == 1) // clamped counter values: the window is non-zero, so the ring was read
    }

    @Test func aStalledRingCountsAsSilence() {
        let bridge = RenderBridge()
        bridge.setTestSignal(.sine(frequency: 1000, amplitude: 0.5))
        Self.feed(bridge, frames: 4096)
        let analyser = VisualiserAnalyser(bridge: bridge)
        let bar = VisualiserAnalyser.bar(containing: 1000)!
        let first = analyser.analyse(nowNanos: Self.frameNanos)
        // Within the stall window the same audio is re-read (large IO buffers), so the bar holds.
        let held = analyser.analyse(nowNanos: 3 * Self.frameNanos)
        #expect(abs(held.bar(bar) - first.bar(bar)) < 1e-6)
        // Long after the last write (engine stopped), the input is silence and the bars fall.
        var t = 3 * Self.frameNanos
        var last = held
        for _ in 0..<90 {
            t += Self.frameNanos
            last = analyser.analyse(nowNanos: t)
        }
        #expect(last.isSilent)
    }

    @Test func analysingAllocatesNothing() throws {
        let bridge = RenderBridge()
        bridge.setTestSignal(.noise(amplitude: 0.5, seed: 3))
        Self.feed(bridge, frames: 8192)
        let analyser = VisualiserAnalyser(bridge: bridge)
        let samples = Self.sine(440)
        var sink: Float = 0
        _ = analyser.analyse(nowNanos: 1) // warm up
        // A `while` loop: at -Onone a `for … in` range loop itself allocates per iteration.
        let count = AllocationCounter.allocations {
            var t: UInt64 = 1
            var i = 0
            while i < 500 {
                t += i < 3 ? Self.frameNanos : 2 * Self.frameNanos // fresh ring reads, then the stalled path
                let a = analyser.analyse(nowNanos: t)
                let b = samples.withUnsafeBufferPointer { analyser.analyse(samples: $0, nowNanos: t + 1) }
                sink += a.bar(10) + b.peak(3) + a.scope(40) + Float(b.barHeight(5))
                i += 1
            }
        }
        #expect(sink.isFinite)
        if let count { #expect(count == 0, "\(count) allocations in 1000 analyses") }
    }
}
