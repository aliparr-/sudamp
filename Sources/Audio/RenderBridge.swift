// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import AudioRender

/// Cumulative render-callback counters (DESIGN §5.2), readable from any thread.
public struct RenderCounters: Sendable, Equatable, Codable {
    public var callbacks: UInt64
    public var frames: UInt64
    /// Reads that returned fewer frames than requested while mpv was streaming (underruns).
    public var shortReads: UInt64
    /// Callbacks whose whole output was silent.
    public var silentCallbacks: UInt64
    /// Reads refused because no AO existed or its lock was contended.
    public var aoUnavailable: UInt64
    /// Callbacks silenced by the host-pause flag without reading.
    public var hostPausedCallbacks: UInt64
    public var lastCallbackNanos: UInt64
    public var lastFrameCount: UInt32
}

/// One render callback as logged by the probe (benchmarks only). `firstR`/`lastR` are raw (pre-gain) samples.
public struct ProbeRecord: Sendable, Equatable {
    public var nanos: UInt64
    public var frames: Int32
    /// Frames the source returned; -1 = no AO, -2 = host-paused (no read).
    public var got: Int32
    public var firstR: Float
    public var lastR: Float
    /// Peak |sample| of the output (post-gain).
    public var peak: Float
    public var rmsL: Float

    public var isSilent: Bool { !(peak > 0) }
}

/// Deterministic signals that replace the pull AO for measurements (eq-selftest, analyser checks). Tools and tests.
public enum TestSignal: Sendable, Equatable {
    /// `amplitude · sin(2π · frequency · n / 48000)` on the left channel (and `rightAmplitude`, default the same, on
    /// the right), silent before frame `startFrame`.
    case sine(frequency: Double, amplitude: Float, rightAmplitude: Float? = nil, startFrame: UInt64 = 0)
    /// Two sines summed, identical on both channels (intermodulation tests).
    case twoTone(frequency: Double, amplitude: Float, frequency2: Double, amplitude2: Float)
    /// Uniform white noise in [-amplitude, amplitude], identical on both channels, from a seeded xorshift.
    case noise(amplitude: Float, seed: UInt64)
    /// Sample n carries the value n on both channels (exact below 2^24 frames): ring integrity checks.
    case counter
}

/// Swift face of the ObjC/C render bridge. Everything here is safe from any thread except where noted; the IO
/// thread itself only ever runs the C render body.
// `enableProbe`, `setSyntheticSource` and `setTestSignal` must not race rendering (documented on each): the
// test-only `synthetic` slot and the tone state's fields are written only while nothing renders this bridge.
// SAFETY: the ObjC bridge and tone pointer are immutable after init; each sa_render_* call is a C11 atomic op.
public final class RenderBridge: @unchecked Sendable {
    private let objc: SARenderBridge
    private var render: OpaquePointer { objc.render }
    /// Keeps a synthetic test source alive while the C side points at it.
    private var synthetic: SyntheticSource?
    /// State for `setTestSignal`, allocated once so the C side never sees a freed pointer.
    private let tone: UnsafeMutablePointer<SAToneSource>

    public init() {
        objc = SARenderBridge()
        tone = .allocate(capacity: 1)
        tone.initialize(to: SAToneSource(kind: Int32(SA_TONE_SINE.rawValue), frequency: 0, amplitude_left: 0,
                                         amplitude_right: 0, frequency2: 0, amplitude2: 0, start_frame: 0, frame: 0,
                                         seed: 1))
    }

    deinit {
        // Restore the AO reader first: the ObjC render block may outlive this object while an engine holds it.
        sa_render_set_reader(render, nil, nil)
        tone.deallocate()
    }

    /// The AVAudioSourceNode (48 kHz stereo deinterleaved Float32) to attach to an engine.
    public var sourceNode: AVAudioSourceNode { objc.sourceNode }
    public var format: AVAudioFormat { objc.format }
    public static var sampleRate: Double { Double(SA_RENDER_SAMPLE_RATE) }
    public static var pauseRampFrames: Int { Int(SA_RENDER_PAUSE_RAMP_FRAMES) }
    public static var ringFrames: Int { Int(SA_RENDER_RING_FRAMES) }
    /// The pull AO compiled into this binary ("sudamp pull AO").
    public static var aoDescription: String { SARenderBridge.aoDescription() }

    // MARK: Controls (any thread)

    /// Host pause: silence within one callback behind a 5 ms ramp; the AO is no longer read while paused.
    public func setHostPaused(_ paused: Bool) { sa_render_set_host_paused(render, paused) }
    public var isHostPaused: Bool { sa_render_host_paused(render) }
    /// The pause ramp has been rendered: output is silent and the AO is no longer read.
    public var isHostPauseSettled: Bool { sa_render_host_pause_settled(render) }

    /// Seconds from a callback's start until its first sample is audible (output latency + IO buffer).
    public func setLatency(seconds: Double) { sa_render_set_latency_ns(render, Int64(max(0, seconds) * 1e9)) }
    public var latencySeconds: Double { Double(sa_render_latency_ns(render)) / 1e9 }
    /// `latencySeconds` in frames at 48 kHz: how far the ring's write position leads what is audible now.
    public var latencyFrames: Int { Int((latencySeconds * Self.sampleRate).rounded()) }

    /// Balance in -1 (left only) ... +1 (right only), as linear per-channel gains (DESIGN §5.4). Winamp-like law: the
    /// centre is unity on both channels (no pan-law dip) and only the opposite channel is attenuated, linearly, so
    /// full left leaves the right channel at exactly 0 (-inf dB).
    public func setBalance(_ balance: Double) {
        let gains = Self.channelGains(balance: balance)
        sa_render_set_channel_gains(render, gains.left, gains.right)
    }

    public static func channelGains(balance: Double) -> (left: Float, right: Float) {
        let b = balance.isNaN ? 0 : Float(min(max(balance, -1), 1))
        return (b > 0 ? 1 - b : 1, b < 0 ? 1 + b : 1)
    }

    /// Linear fade-in from silence over `seconds` of delivered audio (1.5 s launch fade; 50 ms after recovery).
    public func fadeIn(seconds: Double) { sa_render_fade_in(render, seconds) }

    /// Zeroes the output after measuring it, so nothing reaches the EQ, mixer or device (tools and tests).
    public func setOutputMuted(_ muted: Bool) { sa_render_set_output_muted(render, muted) }

    // MARK: Time to first audio

    /// Starts a TTFA measurement: the next callback that outputs a non-zero sample is stamped.
    public func armTTFA() { sa_render_arm_ttfa(render) }
    public var ttfaArmedNanos: UInt64 { sa_render_ttfa_armed_ns(render) }
    /// CLOCK_UPTIME_RAW nanoseconds of the first non-silent callback since `armTTFA()`, if any.
    public var ttfaNanos: UInt64? {
        let t = sa_render_ttfa_ns(render)
        return t == 0 ? nil : t
    }

    /// Milliseconds from `armTTFA()` to first audio, if audio has started.
    public var ttfaMilliseconds: Double? {
        guard let t = ttfaNanos else { return nil }
        let armed = ttfaArmedNanos
        return t >= armed ? Double(t - armed) / 1e6 : nil
    }

    public var counters: RenderCounters {
        let c = sa_render_counters(render)
        return RenderCounters(callbacks: c.callbacks, frames: c.frames, shortReads: c.shortReads,
                              silentCallbacks: c.silentCallbacks, aoUnavailable: c.aoUnavailable,
                              hostPausedCallbacks: c.hostPausedCallbacks, lastCallbackNanos: c.lastCallbackNanos,
                              lastFrameCount: c.lastFrameCount)
    }

    // MARK: Visualiser ring (single consumer)

    /// The newest `count` mono samples ending `lagFrames` before the write position, or nil if unavailable.
    public func copyNewest(_ count: Int, lagFrames: Int = 0) -> [Float]? {
        var out = [Float](repeating: 0, count: count)
        let ok = out.withUnsafeMutableBufferPointer { copyNewest(into: $0, lagFrames: lagFrames) }
        return ok ? out : nil
    }

    /// Allocation-free variant for the 30 Hz visualiser.
    public func copyNewest(into buffer: UnsafeMutableBufferPointer<Float>, lagFrames: Int = 0) -> Bool {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return false }
        return sa_render_ring_copy_newest(render, base, Int32(buffer.count), Int32(lagFrames)) == Int32(buffer.count)
    }

    public var ringFramesWritten: UInt64 { sa_render_ring_written(render) }

    // MARK: Probe (benchmarks)

    /// Enables the per-callback log. Call before the engine starts.
    @discardableResult
    public func enableProbe(capacity: Int) -> Bool { sa_render_probe_enable(render, UInt32(capacity)) }

    public var probeCount: Int { Int(sa_render_probe_count(render)) }

    /// Copies probe records `[from, probeCount)`.
    public func probeRecords(from start: Int = 0) -> [ProbeRecord] {
        let count = probeCount
        guard start < count, let base = sa_render_probe_records(render) else { return [] }
        return (start..<count).map { i in
            let r = base[i]
            return ProbeRecord(nanos: r.t_ns, frames: r.frames, got: r.got, firstR: r.first_r, lastR: r.last_r,
                               peak: r.peak, rmsL: r.rms_l)
        }
    }

    // MARK: Direct rendering (tests, offline checks)

    /// Runs the C render body on the calling thread. Never call while an engine is rendering this bridge.
    @discardableResult
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        var silent = false
        sa_render_process(render, left, right, UInt32(frames), &silent)
        return silent
    }

    /// Replaces the pull AO with a deterministic signal, restarting it at frame 0 (nil restores the pull AO). Call
    /// only while nothing renders this bridge: before the engine starts, while it is stopped, or between offline
    /// renders.
    public func setTestSignal(_ signal: TestSignal?) {
        guard let signal else {
            sa_render_set_reader(render, nil, nil)
            return
        }
        var state = SAToneSource(kind: Int32(SA_TONE_SINE.rawValue), frequency: 0, amplitude_left: 0,
                                 amplitude_right: 0, frequency2: 0, amplitude2: 0, start_frame: 0, frame: 0,
                                 seed: 0x9E37_79B9_7F4A_7C15)
        switch signal {
        case .sine(let frequency, let amplitude, let right, let start):
            state.frequency = frequency
            state.amplitude_left = amplitude
            state.amplitude_right = right ?? amplitude
            state.start_frame = start
        case .twoTone(let frequency, let amplitude, let frequency2, let amplitude2):
            state.frequency = frequency
            state.amplitude_left = amplitude
            state.amplitude_right = amplitude
            state.frequency2 = frequency2
            state.amplitude2 = amplitude2
        case .noise(let amplitude, let seed):
            state.kind = Int32(SA_TONE_NOISE.rawValue)
            state.amplitude_left = amplitude
            state.amplitude_right = amplitude
            state.seed = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        case .counter:
            state.kind = Int32(SA_TONE_COUNTER.rawValue)
        }
        tone.pointee = state
        sa_render_set_reader(render, sa_tone_source_read, UnsafeMutableRawPointer(tone))
    }

    /// Replaces the pull AO with a synthetic source (nil restores the AO). Call before rendering.
    func setSyntheticSource(_ source: SyntheticSource?) {
        synthetic = source
        if let source {
            sa_render_set_reader(render, sa_test_source_read, UnsafeMutableRawPointer(source.state))
        } else {
            sa_render_set_reader(render, nil, nil)
        }
    }
}

/// A constant-valued source for exercising the render body without mpv (tests only).
final class SyntheticSource {
    let state: UnsafeMutablePointer<SATestSource>

    init(left: Float, right: Float, maxFrames: Int = 0, streaming: Bool = true) {
        state = .allocate(capacity: 1)
        state.initialize(to: SATestSource(left: left, right: right, max_frames: Int32(maxFrames), unavailable: false,
                                          streaming: streaming, reads: 0, last_requested: 0, last_delay_ns: 0))
    }

    deinit { state.deallocate() }

    var maxFrames: Int {
        get { Int(state.pointee.max_frames) }
        set { state.pointee.max_frames = Int32(newValue) }
    }
    var unavailable: Bool {
        get { state.pointee.unavailable }
        set { state.pointee.unavailable = newValue }
    }
    var reads: UInt64 { state.pointee.reads }
    var lastRequested: Int { Int(state.pointee.last_requested) }
    var lastDelayNanos: Int64 { state.pointee.last_delay_ns }
}
