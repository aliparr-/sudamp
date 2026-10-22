import Foundation
import Darwin
import Libmpv

let WINAMP_FREQS: [Int] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

func eqAF(gains: [Double], pre: Double) -> String {
    let widths = [1, 1, 1, 1, 1, 1, 1, 1.4, 1.8, 1.8]
    var parts = ["volume@pre=volume=\(pre)dB:precision=float"]
    for i in 0..<10 { parts.append("equalizer@b\(i)=f=\(WINAMP_FREQS[i]):t=q:w=\(widths[i]):g=\(gains[i])") }
    return "@eq:lavfi=[" + parts.joined(separator: ",") + "]"
}

func runEQ(ao: String) {
    signal(SIGPIPE, SIG_IGN)
    let dir = prepRunDir("eq-" + ao)
    var c: Consumer? = nil
    var opts: [(String, String)]
    if ao == "pcm" {
        let fifo = dir + "/audio.fifo"
        unlink(fifo); mkfifo(fifo, 0o600)
        let cc = Consumer(path: fifo, capFrames: 960)
        cc.openFIFO(); cc.start(); c = cc
        opts = pcmOptions(fifo: fifo)
    } else {
        opts = [("vid", "no"), ("audio-display", "no"), ("ao", ao), ("audio-format", "float"), ("audio-samplerate", "48000"),
                ("audio-channels", "stereo"), ("volume", "0")]
    }
    let mpv = MPV(options: opts)
    mpv.startEvents()
    let flat = [Double](repeating: 0, count: 10)
    var marks: [(Double, String)] = []   // (time, label for window ending here)
    func mark(_ label: String) { marks.append((rel(), label)) }

    sleepUntil(0.3); mpv.set("af", eqAF(gains: flat, pre: 0))
    log("af property readback: \(mpv.getString("af") ?? "nil")")
    sleepUntil(1); mpv.cmd("loadfile", MEDIA + "/a.wav")
    sleepUntil(5); mark("baseline (flat)")
    mpv.cmd("af-command", "eq", "g", "12", "b4")
    mpv.cmd("af-command", "eq", "g", "12", "equalizer@b4")
    sleepUntil(10); mark("after af-command g 12 equalizer@b4")
    mpv.cmd("seek", "30", "absolute")
    sleepUntil(15); mark("after seek (no re-send)")
    mpv.cmd("af-command", "eq", "g", "12", "equalizer@b4")
    sleepUntil(20); mark("after re-send g 12")
    mpv.cmd("seek", "20", "absolute"); mpv.cmd("af-command", "eq", "g", "6", "equalizer@b4")
    sleepUntil(25); mark("after seek + immediate af-command g 6")
    mpv.cmd("af-command", "eq", "g", "12", "equalizer@b4")
    sleepUntil(30); mark("after g 12 again")
    mpv.cmd("loadfile", MEDIA + "/a.wav", "replace")
    sleepUntil(35); mark("after loadfile replace (no re-send)")
    mpv.cmd("af-command", "eq", "g", "3", "equalizer")
    sleepUntil(40); mark("after af-command g 3 target=equalizer (type name)")
    mpv.cmd("af-command", "eq", "g", "0", "all")
    sleepUntil(45); mark("after af-command g 0 target=all")
    mpv.cmd("af-command", "eq", "volume", "6dB", "pre")
    mpv.cmd("af-command", "eq", "volume", "6dB", "volume@pre")
    sleepUntil(50); mark("after volume 6dB volume@pre")
    var g = flat; g[4] = 12
    mpv.set("af", eqAF(gains: g, pre: 0))
    sleepUntil(55); mark("after setting af string with b4 g=12, pre 0")
    mpv.cmd("seek", "10", "absolute")
    sleepUntil(60); mark("after seek (string-synced)")
    mpv.cmd("loadfile", MEDIA + "/a.wav", "replace")
    sleepUntil(65); mark("after loadfile (string-synced)")
    // rapid slider drag: 50 commands in 1 s
    var worst = 0.0
    for i in 0..<50 {
        let (r, dt) = mpv.command(["af-command", "eq", "g", String(format: "%.1f", 12.0 - Double(i) * 0.24), "equalizer@b4"])
        worst = max(worst, dt); if r < 0 { log("drag cmd \(i) failed \(r)") }
        usleep(20_000)
    }
    log(String(format: "50 af-commands during drag, worst call latency %.2f ms", worst * 1000))
    sleepUntil(70); mark("after drag to ~0.24 dB")

    if let c {
        c.with { $0.running = false }
        usleep(100_000)
        c.dumpTimeline(dir + "/ticks.csv")
        let ticks = c.with { $0.timeline }
        let ref: Float = 0.1 / Float(2).squareRoot()
        var prev = 0.0
        log("--- measured 1 kHz level at consumer (window = last 1.0 s before each mark) ---")
        for (t, label) in marks {
            let w = ticks.filter { $0.t > t - 1.0 && $0.t <= t - 0.05 && $0.consumed > 0 }
            let rms = w.isEmpty ? 0 : w.map { $0.rmsL }.reduce(0, +) / Float(w.count)
            let under = w.map { $0.underrun }.reduce(0, +)
            log(String(format: "%6.1f..%6.1f  %+6.2f dB  underrun=%d  %@", t - 1.0, t, 20 * log10(Double(rms / ref)), under, label))
            prev = t
        }
        _ = prev
        // continuity check around the af string change at t=50 (looking for discontinuities in the ramp)
        var jumps: [String] = []
        var lastR: Float? = nil
        for k in ticks where k.consumed > 0 && k.t > 49 && k.t < 55 {
            if let l = lastR, abs(k.rFirst - l) > 0.001 { jumps.append(String(format: "t=%.3f %.3fs->%.3fs", k.t, posA(l), posA(k.rFirst))) }
            lastR = k.rLast
        }
        log("ramp discontinuities 49..55 s (af string change at 50): \(jumps)")
        let u = ticks.filter { $0.t > 49 && $0.t < 55 }.map { $0.underrun }.reduce(0, +)
        log("underrun frames 49..55 s: \(u)")
    }
    mpv.destroy()
}
