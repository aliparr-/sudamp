import Foundation
import AVFoundation
import Libmpv
import SudampAO

/// Optional network check: public internet radio through MPVKit libmpv -> pull AO -> AVAudioEngine (muted).
func runNet(_ url: String) {
    let dir = prepRunDir("net")
    _ = dir
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
            rlog.host[i] = mach_absolute_time(); rlog.frames[i] = Int32(n); rlog.got[i] = got; rlog.rms[i] = (s / Float(n)).squareRoot()
            rlog.n.store(i + 1, ordering: .releasing)
        }
        return noErr
    }
    engine.attach(src); engine.connect(src, to: engine.mainMixerNode, format: fmt)
    engine.mainMixerNode.outputVolume = 0
    try! engine.start()
    let mpv = MPV(options: [("vid", "no"), ("audio-display", "no"), ("ao", "pcm"), ("audio-samplerate", "48000"),
                            ("audio-channels", "stereo"), ("cache", "yes"), ("network-timeout", "15"), ("ytdl", "no")], logLevel: "info")
    mpv.startEvents()
    let t0 = rel()
    mpv.cmd("loadfile", url)
    sleepUntil(t0 + 12)
    log("media-title: \(mpv.getString("media-title") ?? "nil")")
    log("metadata/by-key/icy-title: \(mpv.getString("metadata/by-key/icy-title") ?? "nil")")
    log("audio-params: \(mpv.getString("audio-params") ?? "nil")")
    log("file-format: \(mpv.getString("file-format") ?? "nil"), audio-codec: \(mpv.getString("audio-codec-name") ?? "nil"), duration: \(mpv.getString("duration") ?? "nil (live)")")
    log("demuxer-cache-duration: \(mpv.getString("demuxer-cache-duration") ?? "nil"), seekable: \(mpv.getString("seekable") ?? "nil")")
    let N = rlog.n.load(ordering: .acquiring)
    var firstAudio: Double? = nil; var shortAfter = 0
    for i in 0..<N {
        let t = hostToRel(rlog.host[i])
        if firstAudio == nil, rlog.got[i] > 0, rlog.rms[i] > 0 { firstAudio = t }
        if let f = firstAudio, t > f + 0.5, rlog.got[i] >= 0, rlog.got[i] < rlog.frames[i] { shortAfter += 1 }
    }
    log(String(format: "first audible render %.0f ms after loadfile; short reads after start: %d of %d callbacks", ((firstAudio ?? .nan) - t0) * 1000, shortAfter, N))
    mpv.destroy(); engine.stop()
}
