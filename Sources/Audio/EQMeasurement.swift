// SPDX-License-Identifier: GPL-3.0-or-later
// Offline measurements of the real output graph (PLAN M3 eq-selftest, the shelf A/B and the AUPeakLimiter
// evaluation). Everything renders through AVAudioEngine's offline manual rendering mode: no audio device, nothing
// audible, deterministic. AVAudioSourceNode (the C render bridge) renders offline on macOS 27 [measured, M3].
import AVFoundation
import AudioToolbox
import Foundation

public enum EQMeasurement {
    /// One measured value against its bound.
    public struct Check: Sendable, Codable, Equatable {
        public var name: String
        public var expected: Double
        public var measured: Double
        public var tolerance: Double
        /// "within" (|measured - expected| ≤ tolerance) or "atMost" (measured ≤ expected).
        public var kind: String
        public var pass: Bool

        public static func within(_ name: String, _ measured: Double, expected: Double, tolerance: Double) -> Check {
            Check(name: name, expected: expected, measured: round4(measured), tolerance: tolerance, kind: "within",
                  pass: abs(measured - expected) <= tolerance)
        }

        public static func atMost(_ name: String, _ measured: Double, limit: Double) -> Check {
            Check(name: name, expected: limit, measured: round4(measured), tolerance: 0, kind: "atMost",
                  pass: measured <= limit)
        }
    }

    public struct GateReport: Sendable, Codable {
        /// "offline" (manual rendering) — the only mode this function runs in.
        public var mode: String
        /// PLAN M3 gates: 10 bands at +12 dB, preamp +6, flat, balance full left.
        public var gates: [Check]
        /// Extra checks: bypass, headroom cap, analytic model vs measurement on the 17 presets.
        public var extra: [Check]
        public var renderedSeconds: Double
        public var ok: Bool { gates.allSatisfy(\.pass) && extra.allSatisfy(\.pass) }
    }

    /// PLAN M3: each band at +12 dB reads 12.00 ± 0.1 dB at its centre (± 0.25 dB from 12 kHz), preamp +6 reads
    /// 6.00 ± 0.1, flat reads 0.00 ± 0.05 (at every band centre), balance full left puts the right channel ≤ -60 dB.
    /// Measured with the headroom cap off (the filters themselves); the cap is checked separately in `extra`.
    public static func offlineGates() throws -> GateReport {
        let rig = try OfflineRig()
        let engine = rig.engine
        var gates: [Check] = []
        var extra: [Check] = []
        let centres = EQResponse.frequencies

        engine.setEQHeadroom(.off)
        engine.apply(EQSettings.flat)
        for f in centres {
            gates.append(.within("flat@\(Int(f))Hz", try rig.gainDB(at: f).left, expected: 0, tolerance: 0.05))
        }
        for (i, f) in centres.enumerated() {
            var bands = [Float](repeating: 0, count: 10)
            bands[i] = 12
            engine.apply(EQSettings(bands: bands))
            gates.append(.within("band\(i)+12@\(Int(f))Hz", try rig.gainDB(at: f).left, expected: 12,
                                 tolerance: f >= 12_000 ? 0.25 : 0.1))
        }
        engine.apply(EQSettings(preamp: 6))
        gates.append(.within("preamp+6@1000Hz", try rig.gainDB(at: 1000).left, expected: 6, tolerance: 0.1))
        engine.apply(EQSettings.flat)
        engine.setBalance(-1)
        let balanced = try rig.gainDB(at: 1000)
        gates.append(.atMost("balanceFullLeft.right@1000Hz", balanced.right, limit: -60))
        extra.append(.within("balanceFullLeft.left@1000Hz", balanced.left, expected: 0, tolerance: 0.05))
        engine.setBalance(0)

        // Off means untouched, preamp included.
        engine.apply(EQSettings(enabled: false, preamp: 6, bands: [12, 12, 12, 12, 12, 12, 12, 12, 12, 12]))
        extra.append(.within("bypass@1000Hz", try rig.gainDB(at: 1000).left, expected: 0, tolerance: 0.05))

        // Headroom cap (the shipped default): combined boost ≤ +6 dB, shape kept.
        engine.setEQHeadroom(.default)
        var single = [Float](repeating: 0, count: 10)
        single[4] = 12
        engine.apply(EQSettings(bands: single))
        extra.append(.within("cap.band4+12@1000Hz", try rig.gainDB(at: 1000).left, expected: 6, tolerance: 0.1))
        engine.apply(EQSettings(preamp: 6))
        extra.append(.within("cap.preamp+6@1000Hz", try rig.gainDB(at: 1000).left, expected: 6, tolerance: 0.1))
        // Worst case: three overlapping top bands at +12 add up to ~+30 dB; the cap must still hold at the peak.
        let top = EQSettings(preamp: 12, bands: [0, 0, 0, 0, 0, 0, 0, 12, 12, 12])
        engine.apply(top)
        let sweep = stride(from: 10_000.0, through: 20_000.0, by: 250.0).map { $0 }
        var sweepPeak = -Double.infinity
        for f in sweep { sweepPeak = max(sweepPeak, try rig.gainDB(at: f).left) }
        extra.append(.atMost("cap.top3+12,preamp+12.peak10k-20k", sweepPeak, limit: 6.1))
        extra.append(.within("cap.top3+12,preamp+12.peak≈6", sweepPeak, expected: 6, tolerance: 0.15))

        // The analytic model the cap relies on, against the real unit on every built-in preset.
        engine.setEQHeadroom(.off)
        var worst = 0.0
        for preset in EQPresets.builtIn {
            engine.apply(preset.settings())
            for f in centres + [40, 100, 450, 2000, 9000, 19_000] {
                let predicted = EQResponse.gainDB(at: f, bands: preset.bands) + Double(preset.preamp)
                worst = max(worst, abs(try rig.gainDB(at: f).left - predicted))
            }
        }
        extra.append(.atMost("model.presets.maxErrorDB", worst, limit: 0.05))
        engine.apply(EQSettings.flat)
        return GateReport(mode: "offline", gates: gates, extra: extra, renderedSeconds: round4(rig.renderedSeconds))
    }

    // MARK: Shelf A/B (bands 0 and 9)

    public struct ShelfABReport: Sendable, Codable {
        public struct Curve: Sendable, Codable {
            public var variant: String
            /// (frequency Hz, gain dB) with the band at +12 dB.
            public var points: [[Double]]
        }
        public var band0: [Curve]
        public var band9: [Curve]
        /// What a full-scale-ish real signal gains: response averaged over the octave below 40 Hz (band 0) and over
        /// 16–20 kHz (band 9).
        public var band0SubBassMeanDB: [String: Double]
        public var band9AirMeanDB: [String: Double]
        public var decision: String
    }

    /// Band 0 (60 Hz) and band 9 (16 kHz) at +12 dB as 1-octave parametric peaks versus low/high shelves at the
    /// same frequency.
    public static func shelfAB() throws -> ShelfABReport {
        let rig = try OfflineRig()
        let engine = rig.engine
        engine.setEQHeadroom(.off)
        let lowPoints: [Double] = [20, 30, 42.4, 60, 85, 120, 170, 240, 310]
        let highPoints: [Double] = [3000, 6000, 8000, 11_314, 12_000, 14_000, 16_000, 18_000, 20_000, 22_000]
        func curve(band: Int, type: AVAudioUnitEQFilterType, name: String, points: [Double]) throws
            -> ShelfABReport.Curve {
            let unit = engine.eq.bands[band]
            unit.filterType = type
            unit.bandwidth = AudioEngine.eqBandwidthOctaves
            var bands = [Float](repeating: 0, count: 10)
            bands[band] = 12
            engine.apply(EQSettings(bands: bands))
            defer { unit.filterType = .parametric }
            return ShelfABReport.Curve(variant: name, points: try points.map { [$0, round4(try rig.gainDB(at: $0).left)] })
        }
        let b0 = [try curve(band: 0, type: .parametric, name: "parametric60", points: lowPoints),
                  try curve(band: 0, type: .lowShelf, name: "lowShelf60", points: lowPoints)]
        let b9 = [try curve(band: 9, type: .parametric, name: "parametric16k", points: highPoints),
                  try curve(band: 9, type: .highShelf, name: "highShelf16k", points: highPoints)]
        engine.apply(EQSettings.flat)
        func mean(_ c: ShelfABReport.Curve, _ range: ClosedRange<Double>) -> Double {
            let v = c.points.filter { range.contains($0[0]) }.map { $0[1] }
            return round4(v.reduce(0, +) / Double(max(v.count, 1)))
        }
        return ShelfABReport(
            band0: b0, band9: b9,
            band0SubBassMeanDB: Dictionary(uniqueKeysWithValues: b0.map { ($0.variant, mean($0, 20...42.4)) }),
            band9AirMeanDB: Dictionary(uniqueKeysWithValues: b9.map { ($0.variant, mean($0, 16_000...20_000)) }),
            decision: "parametric at both ends: a shelf reads half its gain (6.00 dB) at the labelled frequency, "
                + "failing the band-centre gate, and lifts content below 30 Hz / above 18 kHz by nearly the full "
                + "+12 dB, spending headroom where little is audible")
    }

    // MARK: AUPeakLimiter evaluation

    public struct LimiterReport: Sendable, Codable {
        public struct Setting: Sendable, Codable {
            public var attackSeconds: Double
            public var releaseSeconds: Double
            public var reportedLatencyMs: Double
            /// Onset of a tone burst, limiter chain minus reference chain.
            public var measuredLatencyMs: Double
            /// Latency-aligned residual of white noise (EQ flat) re the signal, by noise peak level in dBFS:
            /// how much the limiter changes content that never exceeds full scale.
            public var nullDepthDBByPeakDBFS: [String: Double]
            /// 1 kHz sine at 0.5 through band 4 at +12 dB (+6 dBFS before limiting): output peak and gain reduction.
            public var sineOverPeakDBFS: Double
            public var sineOverGainReductionDB: Double
            /// 60 Hz at 0.5 + 3 kHz at 0.05 through band 0 at +12 dB (a bass boost driving the output over full
            /// scale): sidebands at 3 kHz ± 60/120 Hz re the 3 kHz tone (gain-reduction modulation).
            public var bassBoostIMDDB: Double
            /// Offline render CPU, limiter chain minus reference, as % of one core at real time.
            public var cpuDeltaPercent: Double
            /// Nulls to ≤ -90 dB at every level below full scale.
            public var transparentBelowFullScale: Bool
            /// Adds ≤ 1 ms of latency.
            public var lowLatency: Bool
            /// When engaged: bass-boost IMD ≤ -60 dB and no more gain reduction than the overload (+6 dB) + 1 dB.
            public var cleanWhenEngaged: Bool
        }
        public var settings: [Setting]
        /// The same overloads without a limiter at the device (hard clip at ±1).
        public var hardClipSineTHDDB: Double
        public var hardClipBassBoostIMDDB: Double
        /// The same overloads with the +6 dB headroom cap instead of a limiter.
        public var capSinePeakDBFS: Double
        public var capBassBoostPeakDBFS: Double
        public var capBassBoostIMDDB: Double
        public var referenceCPUPercent: Double
        public var transparent: Bool
        public var ship: Bool
        public var decision: String
    }

    /// Transparent means all three: nulls to ≤ -90 dB for content that stays below full scale (noise peaks at -20,
    /// -6 and -1 dBFS); adds ≤ 1 ms of latency (pause-to-silence at the device must stay one IO buffer + the 5 ms
    /// ramp, DESIGN §3); and is clean where it actually works, on overloads from EQ boost (bass-boost IMD ≤ -60 dB,
    /// gain reduction ≤ the 6 dB overload + 1 dB). Shipping also needs ≤ 0.5% CPU.
    public static func limiterEvaluation(cpuSeconds: Double = 20) throws -> LimiterReport {
        let reference = try LimiterRig(limiter: nil)
        var settings: [LimiterReport.Setting] = []
        let levels: [Double] = [-20, -6, -1]
        for (attack, release) in [(0.002, 0.005), (0.0005, 0.005), (0.012, 0.024)] {
            let rig = try LimiterRig(limiter: (attack, release))
            let lag = try rig.burstOnsetFrames() - reference.burstOnsetFrames()
            var nulls: [String: Double] = [:]
            for level in levels {
                let amplitude = Float(pow(10, level / 20))
                nulls[String(Int(level))] = round4(try LimiterRig.nullDepth(reference: reference, candidate: rig,
                                                                            amplitude: amplitude, lagFrames: lag))
            }
            let sine = try rig.sineOverload()
            let imd = try rig.bassBoostIMD().imdDB
            let latencyMs = Double(lag) / 48
            settings.append(LimiterReport.Setting(
                attackSeconds: attack, releaseSeconds: release,
                reportedLatencyMs: round4(rig.reportedLatency * 1000), measuredLatencyMs: round4(latencyMs),
                nullDepthDBByPeakDBFS: nulls, sineOverPeakDBFS: round4(sine.peakDBFS),
                sineOverGainReductionDB: round4(sine.gainReductionDB), bassBoostIMDDB: round4(imd),
                cpuDeltaPercent: round4(try rig.cpuPercent(seconds: cpuSeconds) - reference.cpuPercent(seconds: cpuSeconds)),
                transparentBelowFullScale: nulls.values.allSatisfy { $0 <= -90 }, lowLatency: latencyMs <= 1,
                cleanWhenEngaged: imd <= -60 && sine.gainReductionDB <= 6.02 + 1))
        }
        let refCPU = try reference.cpuPercent(seconds: cpuSeconds)
        let cap = try LimiterRig(limiter: nil, headroom: .default)
        let capBass = try cap.bassBoostIMD()
        func passes(_ s: LimiterReport.Setting) -> Bool {
            s.transparentBelowFullScale && s.lowLatency && s.cleanWhenEngaged
        }
        let transparent = settings.contains(where: passes)
        let ship = settings.contains { passes($0) && $0.cpuDeltaPercent <= 0.5 }
        return LimiterReport(
            settings: settings, hardClipSineTHDDB: round4(try reference.sineOverload(hardClip: true).thdDB),
            hardClipBassBoostIMDDB: round4(try reference.bassBoostIMD(hardClip: true).imdDB),
            capSinePeakDBFS: round4(try cap.sineOverload().peakDBFS), capBassBoostPeakDBFS: round4(capBass.peakDBFS),
            capBassBoostIMDDB: round4(capBass.imdDB), referenceCPUPercent: round4(refCPU), transparent: transparent,
            ship: ship,
            decision: ship ? "ship AUPeakLimiter after the EQ"
                : "no limiter: cap combined boost at +6 dB (EQHeadroom.default)")
    }

    // MARK: Helpers

    static func round4(_ v: Double) -> Double { v.isFinite ? (v * 10_000).rounded() / 10_000 : v }

    /// Amplitude of the `frequency` component of `x` (I/Q over a whole number of cycles).
    public static func amplitude(_ x: [Float], frequency: Double, sampleRate: Double = 48_000) -> Double {
        amplitude(x[...], frequency: frequency, sampleRate: sampleRate)
    }

    /// Amplitude of the `frequency` component of `x` (I/Q over a whole number of cycles).
    public static func amplitude(_ x: ArraySlice<Float>, frequency: Double, sampleRate: Double = 48_000) -> Double {
        let cycles = (frequency * Double(x.count) / sampleRate).rounded(.down)
        let n = min(Int((cycles * sampleRate / frequency).rounded()), x.count)
        guard n > 0 else { return 0 }
        var a = 0.0, b = 0.0
        let w = 2 * Double.pi * frequency / sampleRate
        for (i, v) in x.prefix(n).enumerated() {
            a += Double(v) * cos(w * Double(i))
            b += Double(v) * sin(w * Double(i))
        }
        return 2 * (a * a + b * b).squareRoot() / Double(n)
    }

    /// THD (harmonics 2…10 below Nyquist) of a `frequency` sine in `x`, in dB re the fundamental.
    static func thdDB(_ x: ArraySlice<Float>, frequency: Double) -> Double {
        let fundamental = amplitude(x, frequency: frequency)
        var harmonics = 0.0
        for k in 2...10 where Double(k) * frequency < 24_000 {
            let a = amplitude(x, frequency: Double(k) * frequency)
            harmonics += a * a
        }
        return fundamental > 0 ? 10 * log10(max(harmonics, 1e-30) / (fundamental * fundamental)) : 0
    }

    static func dB(_ ratio: Double) -> Double { ratio > 0 ? 20 * log10(ratio) : -200 }
}

/// The real AudioEngine graph in offline mode at unity volume, fed by the render bridge's test signal.
final class OfflineRig {
    let engine: AudioEngine
    private let buffer: AVAudioPCMBuffer
    private(set) var renderedFrames = 0
    static let chunk: AVAudioFrameCount = 4096

    init() throws {
        engine = try AudioEngine(volume: 100, renderingMode: .offline(maximumFrameCount: Self.chunk))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.chunk) else {
            throw CoreAudioError(operation: "offline buffer", status: -1)
        }
        self.buffer = buffer
        try engine.start()
    }

    var renderedSeconds: Double { Double(renderedFrames) / 48_000 }

    /// Renders `frames` and returns both channels.
    func render(_ frames: Int) throws -> (left: [Float], right: [Float]) {
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(frames)
        right.reserveCapacity(frames)
        while left.count < frames {
            let n = AVAudioFrameCount(min(Int(Self.chunk), frames - left.count))
            let status = try engine.renderOffline(n, to: buffer)
            guard status == .success, let data = buffer.floatChannelData else {
                throw CoreAudioError(operation: "renderOffline status \(status.rawValue)", status: -1)
            }
            let got = Int(buffer.frameLength)
            left += UnsafeBufferPointer(start: data[0], count: got)
            right += UnsafeBufferPointer(start: data[1], count: got)
            renderedFrames += got
        }
        return (left, right)
    }

    /// Gain in dB of each channel at `frequency` for a sine of `amplitude` (both channels), after `settle` s.
    func gainDB(at frequency: Double, amplitude: Float = 0.1, settle: Double = 0.25, seconds: Double = 0.5) throws
        -> (left: Double, right: Double) {
        engine.bridge.setTestSignal(.sine(frequency: frequency, amplitude: amplitude))
        let settleFrames = Int(settle * 48_000)
        let out = try render(settleFrames + Int(seconds * 48_000))
        let l = EQMeasurement.amplitude(out.left[settleFrames...], frequency: frequency)
        let r = EQMeasurement.amplitude(out.right[settleFrames...], frequency: frequency)
        return (EQMeasurement.dB(l / Double(amplitude)), EQMeasurement.dB(r / Double(amplitude)))
    }
}

/// source → EQ → [AUPeakLimiter] → mixer, offline: the limiter evaluation's chains.
final class LimiterRig {
    let bridge = RenderBridge()
    let eq = AudioEngine.makeEQ()
    let engine = AVAudioEngine()
    let limiter: AVAudioUnitEffect?
    let headroom: EQHeadroom
    private let buffer: AVAudioPCMBuffer

    init(limiter settings: (attack: Double, release: Double)?, headroom: EQHeadroom = .off) throws {
        self.headroom = headroom
        let format = bridge.format
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: OfflineRig.chunk)
        engine.attach(bridge.sourceNode)
        engine.attach(eq)
        try GraphCompat.connect(engine, bridge.sourceNode, to: eq, format: format)
        if let settings {
            let description = AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            let unit = AVAudioUnitEffect(audioComponentDescription: description)
            AudioUnitSetParameter(unit.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(settings.attack), 0)
            AudioUnitSetParameter(unit.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(settings.release), 0)
            engine.attach(unit)
            try GraphCompat.connect(engine, eq, to: unit, format: format)
            try GraphCompat.connect(engine, unit, to: engine.mainMixerNode, format: format)
            limiter = unit
        } else {
            try GraphCompat.connect(engine, eq, to: engine.mainMixerNode, format: format)
            limiter = nil
        }
        try GraphCompat.connect(engine, engine.mainMixerNode, to: engine.outputNode, format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: OfflineRig.chunk) else {
            throw CoreAudioError(operation: "offline buffer", status: -1)
        }
        self.buffer = buffer
        try engine.start()
    }

    var reportedLatency: Double { limiter?.auAudioUnit.latency ?? 0 }

    func setEQ(_ settings: EQSettings) {
        for (i, g) in settings.bands.enumerated() { eq.bands[i].gain = g }
        eq.globalGain = headroom.appliedPreamp(for: settings)
    }

    func render(_ frames: Int) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(frames)
        while out.count < frames {
            let n = AVAudioFrameCount(min(Int(OfflineRig.chunk), frames - out.count))
            guard try engine.renderOffline(n, to: buffer) == .success, let data = buffer.floatChannelData else {
                throw CoreAudioError(operation: "renderOffline", status: -1)
            }
            out += UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        }
        return out
    }

    /// First frame above 1e-3 of a 1 kHz burst that starts after 0.2 s of silence (which also lets any ringing
    /// from a previous measurement decay), counted from the burst's start.
    func burstOnsetFrames() throws -> Int {
        setEQ(.flat)
        bridge.setTestSignal(.sine(frequency: 1000, amplitude: 0.1, startFrame: 9600))
        let out = try render(19_200)
        return (out[9600...].firstIndex { abs($0) > 1e-3 } ?? 19_200) - 9600
    }

    /// Latency-aligned residual of white noise at `amplitude` peak against `reference` (EQ flat), in dB re the
    /// reference signal.
    static func nullDepth(reference: LimiterRig, candidate: LimiterRig, amplitude: Float, lagFrames: Int) throws
        -> Double {
        let frames = 96_000
        let lag = max(lagFrames, 0)
        reference.setEQ(.flat)
        candidate.setEQ(.flat)
        reference.bridge.setTestSignal(.noise(amplitude: amplitude, seed: 42))
        candidate.bridge.setTestSignal(.noise(amplitude: amplitude, seed: 42))
        let a = try reference.render(frames)
        let b = try candidate.render(frames + lag)
        var residual = 0.0, signal = 0.0
        for i in 9600..<frames {
            let d = Double(b[i + lag]) - Double(a[i])
            residual += d * d
            signal += Double(a[i]) * Double(a[i])
        }
        return signal > 0 ? 10 * log10(max(residual, 1e-30) / signal) : 0
    }

    private func band(_ index: Int, gain: Float) -> EQSettings {
        var bands = [Float](repeating: 0, count: 10)
        bands[index] = gain
        return EQSettings(bands: bands)
    }

    /// A 1 kHz sine at 0.5 through band 4 at +12 dB (≈ +6 dB over full scale before any limiting).
    func sineOverload(hardClip: Bool = false) throws -> (peakDBFS: Double, thdDB: Double, gainReductionDB: Double) {
        let settings = band(4, gain: 12)
        setEQ(settings)
        bridge.setTestSignal(.sine(frequency: 1000, amplitude: 0.5))
        var out = try render(48_000)
        if hardClip { out = out.map { min(max($0, -1), 1) } }
        let tail = out[24_000...]
        let peak = tail.reduce(Float(0)) { max($0, abs($1)) }
        let amp = EQMeasurement.amplitude(tail, frequency: 1000)
        let unlimited = 0.5 * pow(10, (12 + Double(headroom.appliedPreamp(for: settings))) / 20)
        return (EQMeasurement.dB(Double(peak)), EQMeasurement.thdDB(tail, frequency: 1000),
                EQMeasurement.dB(unlimited / max(amp, 1e-9)))
    }

    /// 60 Hz at 0.5 plus 3 kHz at 0.05 through band 0 at +12 dB: the bass alone peaks near +6 dBFS. Returns the output
    /// peak and the 3 kHz ± 60/120 Hz sidebands' power re the 3 kHz tone.
    func bassBoostIMD(hardClip: Bool = false) throws -> (peakDBFS: Double, imdDB: Double) {
        setEQ(band(0, gain: 12))
        bridge.setTestSignal(.twoTone(frequency: 60, amplitude: 0.5, frequency2: 3000, amplitude2: 0.05))
        var out = try render(96_000)
        if hardClip { out = out.map { min(max($0, -1), 1) } }
        let tail = out[48_000...]
        let peak = tail.reduce(Float(0)) { max($0, abs($1)) }
        let carrier = EQMeasurement.amplitude(tail, frequency: 3000)
        var sidebands = 0.0
        for offset in [-120.0, -60, 60, 120] {
            let a = EQMeasurement.amplitude(tail, frequency: 3000 + offset)
            sidebands += a * a
        }
        let imd = carrier > 0 ? 10 * log10(max(sidebands, 1e-30) / (carrier * carrier)) : 0
        return (EQMeasurement.dB(Double(peak)), imd)
    }

    /// Thread CPU to render `seconds` of noise through the chain, as % of real time.
    func cpuPercent(seconds: Double) throws -> Double {
        setEQ(EQSettings(bands: [3, 3, 3, 3, 3, 3, 3, 3, 3, 3]))
        bridge.setTestSignal(.noise(amplitude: 0.3, seed: 7))
        _ = try render(48_000) // warm up
        let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        _ = try render(Int(seconds * 48_000))
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e9
        return cpu / seconds * 100
    }
}
