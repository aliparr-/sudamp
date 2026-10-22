import Foundation
import Darwin
import AVFoundation
import CoreAudio
import Synchronization
import Libmpv
import SudampAO

let BASE = "/tmp/sudamp-spike/engine"
let MEDIA = BASE + "/media"
let WINAMP_FREQS: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func hostToRel(_ h: UInt64) -> Double { Double(h) * Double(tb.numer) / Double(tb.denom) * 1e-9 - T0 }

/// Preallocated render-thread log (no allocation / locks on the RT thread).
final class RenderLog: @unchecked Sendable {
    let cap = 400_000
    let host: UnsafeMutablePointer<UInt64>
    let frames: UnsafeMutablePointer<Int32>
    let got: UnsafeMutablePointer<Int32>
    let rFirst: UnsafeMutablePointer<Float>
    let rLast: UnsafeMutablePointer<Float>
    let rms: UnsafeMutablePointer<Float>
    let n = Atomic<Int>(0)
    let delayNs = Atomic<Int>(0)
    let hostPaused = Atomic<Bool>(false)  // sudamp-side instant pause (render outputs silence, doesn't pull)
    init() {
        host = .allocate(capacity: cap); frames = .allocate(capacity: cap); got = .allocate(capacity: cap)
        rFirst = .allocate(capacity: cap); rLast = .allocate(capacity: cap); rms = .allocate(capacity: cap)
    }
}

func defaultOutputDeviceInfo() -> String {
    var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
    func u32(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var v: UInt32 = 0; var s = UInt32(4)
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v); return v
    }
    var rate: Float64 = 0; var rs = UInt32(8)
    var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(dev, &ra, 0, nil, &rs, &rate)
    var name: Unmanaged<CFString>? = nil; var ns = UInt32(MemoryLayout<CFString?>.size)
    var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(dev, &na, 0, nil, &ns, &name)
    let out = kAudioDevicePropertyScopeOutput
    return "device '\(name?.takeRetainedValue() as String? ?? "?")' rate=\(rate) bufferFrames=\(u32(kAudioDevicePropertyBufferFrameSize, out)) deviceLatency=\(u32(kAudioDevicePropertyLatency, out)) safetyOffset=\(u32(kAudioDevicePropertySafetyOffset, out)) frames"
}

func run() {
    let dir = prepRunDir("pull-engine")
    let rlog = RenderLog()
    log("default output: \(defaultOutputDeviceInfo())")

    // ---- AVAudioEngine graph: source(mpv pull) -> EQ(10 band Winamp) -> mainMixer -> output
    let engine = AVAudioEngine()
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let src = AVAudioSourceNode(format: fmt) { isSilence, _, frameCount, abl -> OSStatus in
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        let L = bufs[0].mData!.assumingMemoryBound(to: Float.self)
        let R = bufs[1].mData!.assumingMemoryBound(to: Float.self)
        let n = Int(frameCount)
        var got: Int32 = 0
        if rlog.hostPaused.load(ordering: .relaxed) {
            memset(L, 0, n * 4); memset(R, 0, n * 4); isSilence.pointee = true; got = -2
        } else {
            let d = Int64(rlog.delayNs.load(ordering: .relaxed)) + Int64(n) * 1_000_000_000 / 48000
            got = sudamp_ao_read(L, R, Int32(n), d)
            if got < 0 { memset(L, 0, n * 4); memset(R, 0, n * 4) }
        }
        let i = rlog.n.load(ordering: .relaxed)
        if i < rlog.cap {
            var s: Float = 0
            for k in 0..<n { s += L[k] * L[k] }
            rlog.host[i] = mach_absolute_time(); rlog.frames[i] = Int32(n); rlog.got[i] = got
            rlog.rFirst[i] = R[0]; rlog.rLast[i] = R[n - 1]; rlog.rms[i] = (s / Float(n)).squareRoot()
            rlog.n.store(i + 1, ordering: .releasing)
        }
        return noErr
    }
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    for (i, f) in WINAMP_FREQS.enumerated() {
        let b = eq.bands[i]; b.filterType = .parametric; b.frequency = f; b.bandwidth = 1.0; b.gain = 0; b.bypass = false
    }
    eq.globalGain = 0
    engine.attach(src); engine.attach(eq)
    engine.connect(src, to: eq, format: fmt)
    engine.connect(eq, to: engine.mainMixerNode, format: fmt)
    engine.mainMixerNode.outputVolume = 0.0      // silent: headless test on the user's machine
    // visualiser tap (post-EQ, pre-volume)
    let tapLock = NSLock()
    var taps: [(Double, Int, Float)] = []
    eq.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, when in
        let n = Int(buf.frameLength); let L = buf.floatChannelData![0]
        var s: Float = 0; for k in 0..<n { s += L[k] * L[k] }
        tapLock.lock(); taps.append((rel(), n, (s / Float(max(n, 1))).squareRoot())); tapLock.unlock()
    }
    var cfgChanges = 0
    NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
        cfgChanges += 1; log("AVAudioEngineConfigurationChange")
    }
    do { try engine.start() } catch { fatalError("engine start \(error)") }
    let pl = engine.outputNode.presentationLatency
    rlog.delayNs.store(Int(pl * 1e9), ordering: .relaxed)
    log(String(format: "engine started: outputNode.presentationLatency=%.2f ms, output format %@", pl * 1000, engine.outputNode.outputFormat(forBus: 0).description))

    // ---- libmpv with ao=pcm (now our pull AO)
    let mpv = MPV(options: [("vid", "no"), ("audio-display", "no"), ("ao", "pcm"), ("audio-samplerate", "48000"),
                            ("audio-channels", "stereo")])
    mpv.startEvents()
    var mon: [(Double, Double, Double?)] = []
    let monLock = NSLock(); nonisolated(unsafe) var monRun = true
    let mth = Thread {
        while true {
            monLock.lock(); let go = monRun; monLock.unlock(); if !go { break }
            let t = rel(); let (tp, lat) = mpv.getDouble("time-pos")
            monLock.lock(); mon.append((t, lat, tp)); monLock.unlock()
            usleep(50_000)
        }
    }
    mth.start()
    var ru0 = rusage()
    var events: [(Double, String)] = []
    func ev(_ s: String) { events.append((rel(), s)); log("== " + s) }

    sleepUntil(0.5); ev("loadfile a"); mpv.cmd("loadfile", MEDIA + "/a.wav")
    sleepUntil(2); getrusage(RUSAGE_SELF, &ru0)
    sleepUntil(6); ev("eq b4 +12"); eq.bands[4].gain = 12
    sleepUntil(8); ev("eq b4 0, preamp +6"); eq.bands[4].gain = 0; eq.globalGain = 6
    sleepUntil(9); var ru1 = rusage(); getrusage(RUSAGE_SELF, &ru1)
    eq.globalGain = 0
    sleepUntil(10); ev("mpv pause"); mpv.set("pause", "yes")
    sleepUntil(12); ev("mpv unpause"); mpv.set("pause", "no")
    sleepUntil(14); ev("host pause (render flag) + mpv pause"); rlog.hostPaused.store(true, ordering: .relaxed); mpv.set("pause", "yes")
    sleepUntil(16); ev("host unpause + mpv unpause"); mpv.set("pause", "no"); rlog.hostPaused.store(false, ordering: .relaxed)
    sleepUntil(18); ev("seek 40"); mpv.cmd("seek", "40", "absolute")
    sleepUntil(22); ev("loadfile b replace"); mpv.cmd("loadfile", MEDIA + "/b.wav", "replace")
    sleepUntil(26); ev("stop"); mpv.cmd("stop")
    sleepUntil(27.5); ev("loadfile a again (after idle)"); mpv.cmd("loadfile", MEDIA + "/a.wav")
    sleepUntil(30)
    monLock.lock(); monRun = false; monLock.unlock()
    usleep(100_000)

    // ---- analysis
    let N = rlog.n.load(ordering: .acquiring)
    log("render callbacks: \(N), ao inits: \(sudamp_ao_init_count()), cfgChanges: \(cfgChanges)")
    var sizes: [Int32: Int] = [:]
    for i in 0..<N { sizes[rlog.frames[i], default: 0] += 1 }
    log("render quantum sizes: \(sizes)")
    let cpu = Double(ru1.ru_utime.tv_sec - ru0.ru_utime.tv_sec) + Double(ru1.ru_utime.tv_usec - ru0.ru_utime.tv_usec) / 1e6
        + Double(ru1.ru_stime.tv_sec - ru0.ru_stime.tv_sec) + Double(ru1.ru_stime.tv_usec - ru0.ru_stime.tv_usec) / 1e6
    log(String(format: "process CPU 2..9 s (decode+resample+engine+EQ+tap): %.3f s over 7 s = %.1f%% of one core", cpu, cpu / 7 * 100))
    struct CB { var t: Double; var n: Int32; var got: Int32; var rf: Float; var rl: Float; var rms: Float }
    var cbs: [CB] = []
    for i in 0..<N { cbs.append(CB(t: hostToRel(rlog.host[i]), n: rlog.frames[i], got: rlog.got[i], rf: rlog.rFirst[i], rl: rlog.rLast[i], rms: rlog.rms[i])) }
    var s = "t,frames,got,rFirst,rLast,rmsL\n"
    for c in cbs { s += String(format: "%.5f,%d,%d,%.7f,%.7f,%.6f\n", c.t, c.n, c.got, c.rf, c.rl, c.rms) }
    FileManager.default.createFile(atPath: dir + "/render.csv", contents: s.data(using: .utf8))
    // underruns during steady play 2..6 s
    let steady = cbs.filter { $0.t > 2 && $0.t < 6 }
    log("steady 2..6 s: \(steady.count) callbacks, short reads: \(steady.filter { $0.got >= 0 && $0.got < $0.n }.count)")
    let ival = zip(steady.dropFirst(), steady).map { $0.t - $1.t }
    if !ival.isEmpty { log(String(format: "callback interval mean %.2f ms, max %.2f ms", ival.reduce(0, +) / Double(ival.count) * 1000, ival.max()! * 1000)) }
    // time-pos vs rendered position
    monLock.lock(); let m = mon; monLock.unlock()
    var leads: [Double] = []
    for (t, _, tp) in m where t > 2 && t < 6 {
        if let tp, let c = cbs.last(where: { $0.t <= t }) { leads.append(tp - posA(c.rl)) }
    }
    if !leads.isEmpty { log(String(format: "time-pos minus last-rendered source pos (2..6 s): mean %.1f ms, min %.1f, max %.1f (negative = time-pos lags render by output latency)", leads.reduce(0, +) / Double(leads.count) * 1000, leads.min()! * 1000, leads.max()! * 1000)) }
    let lats = m.map { $0.1 * 1000 }.sorted()
    log(String(format: "get_property(time-pos) latency over run: p50 %.3f ms, p99 %.3f ms, max %.3f ms", lats[lats.count / 2], lats[Int(Double(lats.count) * 0.99)], lats.last!))
    // events
    for (t, name) in events {
        let after = cbs.filter { $0.t >= t }
        let firstSilent = after.first(where: { $0.got <= 0 || $0.rms == 0 })
        switch name {
        case "mpv pause", "host pause (render flag) + mpv pause", "stop":
            if let f = firstSilent { log(String(format: "%@: first silent render callback %.1f ms after command (+ %.1f ms output latency)", name, (f.t - t) * 1000, pl * 1000)) }
            let leaked = after.prefix(while: { $0.got > 0 && $0.rms > 0 }).map { Int($0.got) }.reduce(0, +)
            log("   frames rendered after command before silence: \(leaked) (\(Double(leaked) / 48.0) ms)")
        case "mpv unpause", "host unpause + mpv unpause":
            let before = cbs.last(where: { $0.t < t && $0.got > 0 && $0.rms > 0 })
            if let f = after.first(where: { $0.got > 0 && $0.rms > 0 }), let b = before {
                log(String(format: "%@: audio resumes %.1f ms after command; source pos before pause %.4f s, after resume %.4f s (gap %.1f ms of source)", name, (f.t - t) * 1000, posA(b.rl), posA(f.rf), (posA(f.rf) - posA(b.rl)) * 1000))
            }
        case "seek 40":
            if let f = after.first(where: { $0.got > 0 && abs(posA($0.rf) - 40) < 0.5 }) {
                let stale = after.prefix(while: { $0.t < f.t }).filter { $0.got > 0 && $0.rms > 0 }.map { Int($0.got) }.reduce(0, +)
                log(String(format: "seek 40: new audio at render %.1f ms after command (first pos %.4f s); stale frames rendered meanwhile: %d (%.1f ms)", (f.t - t) * 1000, posA(f.rf), stale, Double(stale) / 48.0))
            }
        case "loadfile b replace":
            if let f = after.first(where: { $0.got > 0 && $0.rf > $0.rl + 1e-5 }) {
                let stale = after.prefix(while: { $0.t < f.t }).filter { $0.got > 0 && $0.rms > 0 && $0.rl > $0.rf }.map { Int($0.got) }.reduce(0, +)
                log(String(format: "loadfile b: B audio at render %.1f ms after command (B pos %.4f s); stale A frames rendered: %d (%.1f ms)", (f.t - t) * 1000, posB(f.rf), stale, Double(stale) / 48.0))
            }
        case "loadfile a again (after idle)", "loadfile a":
            if let f = after.first(where: { $0.got > 0 && $0.rms > 0 }) {
                log(String(format: "%@: first audio at render %.1f ms after command (pos %.4f s)", name, (f.t - t) * 1000, posA(f.rf)))
            }
        default: break
        }
    }
    // EQ via tap
    tapLock.lock(); let tp = taps; tapLock.unlock()
    if tp.count > 2 {
        let iv = zip(tp.dropFirst(), tp).map { $0.0 - $1.0 }
        log(String(format: "tap: %d buffers, frameLength %@, mean interval %.1f ms", tp.count, Set(tp.map { $0.1 }).description, iv.reduce(0, +) / Double(iv.count) * 1000))
    }
    let ref: Float = 0.1 / Float(2).squareRoot()
    func tapDB(_ a: Double, _ b: Double) -> String {
        let w = tp.filter { $0.0 > a && $0.0 < b }.map { $0.2 }
        return w.isEmpty ? "n/a" : String(format: "%+.2f dB", 20 * log10(w.reduce(0, +) / Float(w.count) / ref))
    }
    log("tap 1 kHz level: flat(4-6 s) \(tapDB(4, 6)), b4+12 (6.3-8 s) \(tapDB(6.3, 8)), preamp+6 (8.3-9 s) \(tapDB(8.3, 9))")
    mpv.destroy()
    engine.stop()
    log("done")
}

signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "eq" { runEQPull() } else if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "net" { runNet(CommandLine.arguments[2]) } else { run() }
