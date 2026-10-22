// SPDX-License-Identifier: GPL-3.0-or-later
// Visualiser data (DESIGN §5.4): the newest 1024 samples from the render bridge's SPSC ring, Hann window, vDSP FFT,
// 19 log-spaced bars (40 Hz–16 kHz) with falloff and peaks, and a 76-sample oscilloscope. SkinKit/SkinUI draw it.
//
// The zero-allocation shape (every buffer and the vDSP_DFT_zrop setup made once, the Hann window precomputed, the
// even/odd packing for the real-to-complex DFT) is adapted from hfyeomans/MacAmp @ cb0c77f
// `MacAmpApp/Audio/VisualizerScratchBuffers.swift`. The band layout, energy sums, falloff and peak model are our
// own; the default falloff and peak gravity follow Winamp's defaults as documented in Webamp @ 7734cd3
// `components/VisPainter.ts` (12/16 rows per frame; peaks accelerate ×1.1 per frame), converted to per-second rates.
//
// MacAmp notice:
//
// MIT License
//
// Copyright (c) 2025-2026 Hank Yeomans
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
import Accelerate
import Core
import Foundation

/// One analysed visualiser frame: 19 bar levels and peaks in 0...1 and 76 scope samples in -1...1. A plain value
/// with inline (SIMD) storage, so producing and copying it never allocates.
public struct VisualiserFrame: Sendable, Equatable {
    public static let barCount = 19
    public static let scopeCount = 76

    var barStorage = SIMD32<Float>()
    var peakStorage = SIMD32<Float>()
    var scopeLow = SIMD64<Float>()
    var scopeHigh = SIMD16<Float>()
    /// The ring's total frames written when this frame was analysed (unchanged between frames = no new audio).
    public var framesWritten: UInt64 = 0

    public init() {}

    /// Copies `barCount` bars and peaks and `scopeCount` scope samples out of plain buffers.
    init(bars: UnsafePointer<Float>, peaks: UnsafePointer<Float>, scope: UnsafePointer<Float>, framesWritten: UInt64) {
        var i = 0
        while i < Self.barCount {
            barStorage[i] = bars[i]
            peakStorage[i] = peaks[i]
            i += 1
        }
        i = 0
        while i < 64 {
            scopeLow[i] = scope[i]
            i += 1
        }
        while i < Self.scopeCount {
            scopeHigh[i - 64] = scope[i]
            i += 1
        }
        self.framesWritten = framesWritten
    }

    /// Bar level 0...1 (0 = floor, 1 = ceiling of `VisualiserAnalyser.Settings`).
    public func bar(_ index: Int) -> Float { index >= 0 && index < Self.barCount ? barStorage[index] : 0 }
    /// Peak marker level 0...1.
    public func peak(_ index: Int) -> Float { index >= 0 && index < Self.barCount ? peakStorage[index] : 0 }
    /// Oscilloscope sample -1...1, oldest first.
    public func scope(_ index: Int) -> Float {
        if index >= 0 && index < 64 { return scopeLow[index] }
        if index >= 64 && index < Self.scopeCount { return scopeHigh[index - 64] }
        return 0
    }

    /// Bar height in rows (SkinKit's `VisualizerFrame.bars`: 0...16 for the main window).
    public func barHeight(_ index: Int, rows: Int = 16) -> Int { Int((bar(index) * Float(rows)).rounded()) }
    /// Peak height in rows (0 = none).
    public func peakHeight(_ index: Int, rows: Int = 16) -> Int { Int((peak(index) * Float(rows)).rounded()) }
    /// Scope row, 0 = top (SkinKit's `VisualizerFrame.scope`: 0...15).
    public func scopeRow(_ index: Int, rows: Int = 16) -> Int {
        let row = Int(((1 - scope(index)) / 2 * Float(rows - 1)).rounded())
        return min(max(row, 0), rows - 1)
    }

    /// Allocating copies, for tests, tools and JSON.
    public var bars: [Float] { (0..<Self.barCount).map(bar) }
    public var peaks: [Float] { (0..<Self.barCount).map(peak) }
    public var scope: [Float] { (0..<Self.scopeCount).map(scope) }

    /// Every bar and peak at 0.
    public var isSilent: Bool { barStorage == SIMD32() && peakStorage == SIMD32() }
}

/// Turns the render bridge's mono ring into `VisualiserFrame`s, at whatever rate the caller draws (30 Hz). Not
/// thread-safe: use one instance from one thread (SkinUI's display link on the main thread). Nothing allocates
/// after `init`.
///
/// The ring is written when a callback renders, `bridge.latencySeconds` (output latency + one IO buffer, refreshed
/// by `AudioEngine` on start and after every device change) before those samples are heard, so the window ends that
/// many frames behind the write position to match what is audible. If the ring hasn't advanced for 150 ms (engine
/// stopped or idle-stopped), the input counts as silence and the bars fall.
public final class VisualiserAnalyser {
    public struct Settings: Sendable, Equatable {
        /// Band level (dB re a full-scale sine) drawn as an empty bar.
        public var floorDB: Float = -60
        /// Band level drawn as a full bar.
        public var ceilingDB: Float = -6
        /// How fast a bar falls, in full heights per second (Winamp "moderate": 12/16 rows per 30 Hz frame).
        public var barFalloffPerSecond: Float = 12.0 / 16.0 * 30 / 16
        /// A peak's initial fall speed, in full heights per second (3/256 rows per 30 Hz frame).
        public var peakInitialSpeed: Float = 3.0 / 256.0 * 30 / 16
        /// Factor a falling peak's speed grows by each second (×1.1 per 30 Hz frame).
        public var peakAccelerationPerSecond: Float = Float(pow(1.1, 30.0))

        public init() {}
    }

    public static let windowSize = 1024
    public static let minFrequency = 40.0
    public static let maxFrequency = 16_000.0
    public static let sampleRate = 48_000.0

    public var settings: Settings
    private let bridge: RenderBridge?
    private let setup: vDSP_DFT_Setup
    private let samples: UnsafeMutablePointer<Float>
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let inReal: UnsafeMutablePointer<Float>
    private let inImag: UnsafeMutablePointer<Float>
    private let outReal: UnsafeMutablePointer<Float>
    private let outImag: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    /// Per bar: first and last FFT bin whose centre lies in the band (first = -1 for bands narrower than a bin,
    /// which interpolate at their centre bin instead).
    private let bandFirst: UnsafeMutablePointer<Int>
    private let bandLast: UnsafeMutablePointer<Int>
    private let bandCentre: UnsafeMutablePointer<Float>
    /// Falloff state and the scope scratch (plain buffers, so the hot path has no generic code).
    private let bars: UnsafeMutablePointer<Float>
    private let peaks: UnsafeMutablePointer<Float>
    private let peakSpeed: UnsafeMutablePointer<Float>
    private let scope: UnsafeMutablePointer<Float>
    /// Power of a full-scale sine summed over its bins (Hann, vDSP's ×2 DFT scaling): N² · 3/8.
    private let fullScalePower: Float
    private var lastNanos: UInt64 = 0
    /// Samples handed to `analyse(samples:nowNanos:)` so far (its frames' `framesWritten`).
    private var framesFed: UInt64 = 0
    private var lastWritten: UInt64 = .max
    private var lastAdvanceNanos: UInt64 = 0
    /// The ring must advance at least this often to count as playing (an IO buffer is 10.7 ms on built-in output).
    static let stallNanos: UInt64 = 150_000_000

    /// Analyses `bridge`'s ring (nil: only `analyse(samples:nowNanos:)` is useful).
    public init(bridge: RenderBridge?, settings: Settings = Settings()) {
        self.bridge = bridge
        self.settings = settings
        let n = Self.windowSize
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else {
            fatalError("vDSP_DFT_zrop_CreateSetup(\(n)) failed") // only for invalid lengths; 1024 is valid
        }
        self.setup = setup
        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        samples = buffer(n)
        window = buffer(n)
        windowed = buffer(n)
        inReal = buffer(n / 2)
        inImag = buffer(n / 2)
        outReal = buffer(n / 2)
        outImag = buffer(n / 2)
        power = buffer(n / 2)
        bars = buffer(VisualiserFrame.barCount)
        peaks = buffer(VisualiserFrame.barCount)
        peakSpeed = buffer(VisualiserFrame.barCount)
        scope = buffer(VisualiserFrame.scopeCount)
        bandCentre = buffer(VisualiserFrame.barCount)
        bandFirst = .allocate(capacity: VisualiserFrame.barCount)
        bandLast = .allocate(capacity: VisualiserFrame.barCount)
        for (i, band) in Self.bandLayout().enumerated() {
            (bandFirst + i).initialize(to: band.first)
            (bandLast + i).initialize(to: band.last)
            bandCentre[i] = band.centreBin
        }
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        fullScalePower = Float(n * n) * 3 / 8
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
        for p in [samples, window, windowed, inReal, inImag, outReal, outImag, power, bars, peaks, peakSpeed, scope,
                  bandCentre] { p.deallocate() }
        bandFirst.deallocate()
        bandLast.deallocate()
    }

    /// The 20 band edges in Hz (log-spaced, 40 Hz–16 kHz).
    public static var bandEdges: [Double] {
        (0...VisualiserFrame.barCount).map {
            minFrequency * pow(maxFrequency / minFrequency, Double($0) / Double(VisualiserFrame.barCount))
        }
    }

    /// The bar whose band contains `frequency`, if any.
    public static func bar(containing frequency: Double) -> Int? {
        let edges = bandEdges
        return (0..<VisualiserFrame.barCount).first { edges[$0] <= frequency && frequency < edges[$0 + 1] }
    }

    static func bandLayout() -> [(first: Int, last: Int, centreBin: Float)] {
        let binHz = sampleRate / Double(windowSize)
        let edges = bandEdges
        return (0..<VisualiserFrame.barCount).map { i in
            let first = Int((edges[i] / binHz).rounded(.up))
            let last = Int((edges[i + 1] / binHz).rounded(.up)) - 1
            let centre = Float((edges[i] * edges[i + 1]).squareRoot() / binHz)
            return last >= first ? (first, min(last, windowSize / 2 - 1), centre) : (-1, -1, centre)
        }
    }

    /// Forgets falloff state, so the next frame starts from silence.
    public func reset() {
        bars.update(repeating: 0, count: VisualiserFrame.barCount)
        peaks.update(repeating: 0, count: VisualiserFrame.barCount)
        peakSpeed.update(repeating: 0, count: VisualiserFrame.barCount)
        framesFed = 0
        lastNanos = 0
        lastWritten = .max
        lastAdvanceNanos = 0
    }

    /// The next frame from the bridge's ring at `nowNanos` (CLOCK_UPTIME_RAW, `monotonicNanos()`).
    public func analyse(nowNanos: UInt64 = monotonicNanos()) -> VisualiserFrame {
        var written: UInt64 = 0
        var fresh = false
        if let bridge {
            written = bridge.ringFramesWritten
            if written != lastWritten {
                lastWritten = written
                lastAdvanceNanos = nowNanos
            }
            // A frame between two callbacks (large IO buffers) re-reads the same window; only a ring that has not
            // advanced for `stallNanos` counts as silence.
            if nowNanos < lastAdvanceNanos || nowNanos - lastAdvanceNanos < Self.stallNanos {
                fresh = bridge.copyNewest(into: UnsafeMutableBufferPointer(start: samples, count: Self.windowSize),
                                          lagFrames: bridge.latencyFrames)
            }
        }
        if !fresh { samples.update(repeating: 0, count: Self.windowSize) }
        return process(nowNanos: nowNanos, framesWritten: written)
    }

    /// The next frame from `input` (the newest `windowSize` samples, oldest first; shorter input is zero-padded at
    /// the start) instead of the ring. For tests and tools.
    public func analyse(samples input: UnsafeBufferPointer<Float>, nowNanos: UInt64) -> VisualiserFrame {
        let n = Self.windowSize
        let count = min(input.count, n)
        samples.update(repeating: 0, count: n - count)
        if let base = input.baseAddress, count > 0 {
            (samples + (n - count)).update(from: base + (input.count - count), count: count)
        }
        framesFed &+= UInt64(count)
        return process(nowNanos: nowNanos, framesWritten: framesFed)
    }

    /// The hot path. Plain `while` loops and vDSP only: at -Onone a `for … in` range loop allocates an iterator box
    /// per iteration, and this runs at 30 Hz in debug builds too (the test counts allocations in both).
    private func process(nowNanos: UInt64, framesWritten: UInt64) -> VisualiserFrame {
        let n = Self.windowSize
        let half = n / 2
        let dt: Float = lastNanos == 0 || nowNanos <= lastNanos
            ? 1.0 / 30 : min(Float(Double(nowNanos - lastNanos) / 1e9), 0.25)
        lastNanos = nowNanos

        // Oscilloscope: 76 evenly spaced raw samples across the window, into the scratch scope buffer.
        var x = 0
        while x < VisualiserFrame.scopeCount {
            scope[x] = min(max(samples[x * n / VisualiserFrame.scopeCount], -1), 1)
            x += 1
        }

        // Spectrum: Hann window, real-to-complex DFT (even samples → real, odd → imaginary), bin powers.
        vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(n))
        var split = DSPSplitComplex(realp: inReal, imagp: inImag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
        vDSP_DFT_Execute(setup, inReal, inImag, outReal, outImag)
        var out = DSPSplitComplex(realp: outReal, imagp: outImag)
        vDSP_zvmags(&out, 1, power, 1, vDSP_Length(half))
        power[0] = 0 // DC and Nyquist share bin 0 in vDSP's packed output; neither is drawn

        let range = max(settings.ceilingDB - settings.floorDB, 1)
        let falloff = settings.barFalloffPerSecond * dt
        let growth = powf(settings.peakAccelerationPerSecond, dt)
        var b = 0
        while b < VisualiserFrame.barCount {
            var p: Float = 0
            let first = bandFirst[b]
            if first >= 0 {
                vDSP_sve(power + first, 1, &p, vDSP_Length(bandLast[b] - first + 1))
            } else {
                let centre = bandCentre[b]
                let lo = min(max(Int(centre), 1), half - 2)
                let frac = min(max(centre - Float(lo), 0), 1)
                p = power[lo] * (1 - frac) + power[lo + 1] * frac
            }
            let db = p > 0 ? 10 * log10f(p / fullScalePower) : -200
            let level = min(max((db - settings.floorDB) / range, 0), 1)
            let bar = max(level, bars[b] - falloff)
            bars[b] = bar
            if bar >= peaks[b] {
                peaks[b] = bar
                peakSpeed[b] = settings.peakInitialSpeed
            } else {
                peaks[b] = max(peaks[b] - peakSpeed[b] * dt, bar, 0)
                peakSpeed[b] *= growth
            }
            b += 1
        }
        return VisualiserFrame(bars: bars, peaks: peaks, scope: scope, framesWritten: framesWritten)
    }
}
