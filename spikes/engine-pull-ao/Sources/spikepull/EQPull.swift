import Foundation
import AVFoundation
import Libmpv
import SudampAO

func eqAF(gains: [Double], pre: Double) -> String {
    let widths = [1, 1, 1, 1, 1, 1, 1, 1.4, 1.8, 1.8]
    var parts = ["volume@pre=volume=\(pre)dB:precision=float"]
    for i in 0..<10 { parts.append("equalizer@b\(i)=f=\(Int(WINAMP_FREQS[i])):t=q:w=\(widths[i]):g=\(gains[i])") }
    return "@eq:lavfi=[" + parts.joined(separator: ",") + "]"
}

/// Option A EQ checks measured at the render callback (post mpv af chain), via the pull AO (~10 ms latency).
func runEQPull() {
    let dir = prepRunDir("eq-pull")
    let rlog = RenderLog()
    let engine = AVAudioEngine()
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let src = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl -> OSStatus in
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        let L = bufs[0].mData!.assumingMemoryBound(to: Float.self), R = bufs[1].mData!.assumingMemoryBound(to: Float.self)
        let n = Int(frameCount)
        let got = sudamp_ao_read(L, R, Int32(n), Int64(n) * 1_000_000_000 / 48000)
        if got < 0 { memset(L, 0, n * 4); memset(R, 0, n * 4) }
        let i = rlog.n.load(ordering: .relaxed)
        if i < rlog.cap {
            var s: Float = 0; for k in 0..<n { s += L[k] * L[k] }
            rlog.host[i] = mach_absolute_time(); rlog.frames[i] = Int32(n); rlog.got[i] = got
            rlog.rFirst[i] = R[0]; rlog.rLast[i] = R[n - 1]; rlog.rms[i] = (s / Float(n)).squareRoot()
            rlog.n.store(i + 1, ordering: .releasing)
        }
        return noErr
    }
    engine.attach(src); engine.connect(src, to: engine.mainMixerNode, format: fmt)
    engine.mainMixerNode.outputVolume = 0
    try! engine.start()
    let mpv = MPV(options: [("vid", "no"), ("audio-display", "no"), ("ao", "pcm"), ("audio-samplerate", "48000"), ("audio-channels", "stereo")])
    let armLock = NSLock(); nonisolated(unsafe) var reapply: String? = nil
    mpv.onEvent = { desc in
        if desc.hasPrefix("playback-restart") {
            armLock.lock(); let r = reapply; reapply = nil; armLock.unlock()
            if let r { mpv.cmd("af-command", "eq", "g", r, "equalizer@b4") }
        }
    }
    mpv.startEvents()
    let flat = [Double](repeating: 0, count: 10)
    var marks: [(Double, String)] = []
    func mark(_ l: String) { marks.append((rel(), l)); log("-- mark: \(l)") }

    sleepUntil(0.3); mpv.set("af", eqAF(gains: flat, pre: 0))
    sleepUntil(1); mpv.cmd("loadfile", MEDIA + "/a.wav")
    sleepUntil(3); mark("baseline flat")
    mpv.cmd("af-command", "eq", "g", "12", "b4")
    mpv.cmd("af-command", "eq", "g", "12", "equalizer@b4")
    sleepUntil(6); mark("af-command g 12 equalizer@b4 (after failed 'b4')")
    mpv.cmd("seek", "30", "absolute")
    sleepUntil(9); mark("after seek, no re-send")
    mpv.cmd("af-command", "eq", "g", "12", "equalizer@b4")
    sleepUntil(12); mark("re-sent g 12")
    mpv.cmd("seek", "20", "absolute"); mpv.cmd("af-command", "eq", "g", "6", "equalizer@b4")
    sleepUntil(15); mark("seek + immediate af-command g 6")
    mpv.cmd("af-command", "eq", "g", "12", "equalizer@b4")
    sleepUntil(18); mark("g 12 again")
    mpv.cmd("loadfile", MEDIA + "/a.wav", "replace")
    sleepUntil(21); mark("after loadfile replace, no re-send")
    armLock.lock(); reapply = "12"; armLock.unlock(); mpv.cmd("seek", "40", "absolute")
    sleepUntil(24); mark("seek + re-apply g 12 on playback-restart")
    armLock.lock(); reapply = "12"; armLock.unlock(); mpv.cmd("loadfile", MEDIA + "/a.wav", "replace")
    sleepUntil(27); mark("loadfile + re-apply g 12 on playback-restart")
    mpv.cmd("af-command", "eq", "g", "3", "equalizer")
    sleepUntil(30); mark("target 'equalizer' (type name) g 3 -> all bands")
    mpv.cmd("af-command", "eq", "g", "0", "all")
    sleepUntil(33); mark("target 'all' g 0")
    mpv.cmd("af-command", "eq", "volume", "6dB", "pre")
    mpv.cmd("af-command", "eq", "volume", "6dB", "volume@pre")
    sleepUntil(36); mark("volume 6dB volume@pre (after failed 'pre')")
    var g = flat; g[4] = 12
    let tAf = rel(); mpv.set("af", eqAF(gains: g, pre: 0))
    sleepUntil(39); mark("af string set with b4 g=12, pre 0 (mid-playback)")
    mpv.cmd("seek", "10", "absolute")
    sleepUntil(42); mark("seek with string-synced gains")
    mpv.cmd("loadfile", MEDIA + "/a.wav", "replace")
    sleepUntil(45); mark("loadfile with string-synced gains")
    var worst = 0.0; var fails = 0
    let tDrag = rel()
    for i in 0..<50 {
        let (r, dt) = mpv.command(["af-command", "eq", "g", String(format: "%.2f", 12.0 - Double(i) * 0.24), "equalizer@b4"])
        worst = max(worst, dt); if r < 0 { fails += 1 }
        usleep(20_000)
    }
    log(String(format: "drag: 50 af-commands over %.2f s, fails %d, worst call %.2f ms", rel() - tDrag, fails, worst * 1000))
    sleepUntil(48); mark("after drag to 0.24 dB")
    log("af readback: \(mpv.getString("af") ?? "nil")")

    let N = rlog.n.load(ordering: .acquiring)
    struct CB { var t: Double; var got: Int32; var rf: Float; var rl: Float; var rms: Float }
    var cbs: [CB] = []
    for i in 0..<N { cbs.append(CB(t: hostToRel(rlog.host[i]), got: rlog.got[i], rf: rlog.rFirst[i], rl: rlog.rLast[i], rms: rlog.rms[i])) }
    let ref: Float = 0.1 / Float(2).squareRoot()
    log("--- 1 kHz level at render (post mpv af), window = 1.0 s before each mark ---")
    for (t, l) in marks {
        let w = cbs.filter { $0.t > t - 1.0 && $0.t < t - 0.02 && $0.got > 0 }.map { $0.rms }
        let db = w.isEmpty ? Float.nan : 20 * log10(w.reduce(0, +) / Float(w.count) / ref)
        log(String(format: "%6.2f  %+7.2f dB  %@", t, db, l))
    }
    func gaps(_ a: Double, _ b: Double) -> String {
        let w = cbs.filter { $0.t > a && $0.t < b }
        let silent = w.filter { $0.got <= 0 || $0.rms == 0 }.count
        var jumps: [String] = []
        for (x, y) in zip(w, w.dropFirst()) where x.got > 0 && y.got > 0 {
            let d = posA(y.rf) - posA(x.rl)
            if d > 0.03 || d < -0.001 { jumps.append(String(format: "%.3f:%+.3fs", y.t, d)) }
        }
        return "silent callbacks \(silent), position jumps \(jumps)"
    }
    log("af string change at \(String(format: "%.2f", tAf)): \(gaps(tAf - 0.2, tAf + 1.0))")
    log("drag window: \(gaps(tDrag, tDrag + 1.2))")
    var s = "t,got,rFirst,rLast,rmsL\n"
    for c in cbs { s += String(format: "%.5f,%d,%.7f,%.7f,%.6f\n", c.t, c.got, c.rf, c.rl, c.rms) }
    FileManager.default.createFile(atPath: dir + "/render.csv", contents: s.data(using: .utf8))
    mpv.destroy(); engine.stop()
}
