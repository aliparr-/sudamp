import Foundation
import Darwin
import Libmpv

// MARK: - time + logging

@inline(__always) func mono() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9 }

nonisolated(unsafe) var T0 = mono()
@inline(__always) func rel() -> Double { mono() - T0 }

let logLock = NSLock()
nonisolated(unsafe) var logFH: FileHandle? = nil
nonisolated(unsafe) var mpvLogFH: FileHandle? = nil

func log(_ s: String) {
    let line = String(format: "[%8.3f] ", rel()) + s
    logLock.lock()
    print(line); fflush(stdout)
    logFH?.write((line + "\n").data(using: .utf8)!)
    logLock.unlock()
}
func mpvlog(_ s: String) {
    let line = String(format: "[%8.3f] ", rel()) + s
    logLock.lock()
    mpvLogFH?.write((line + "\n").data(using: .utf8)!)
    logLock.unlock()
}

// MARK: - WAV generation

func writeWav(path: String, rate: Int, seconds: Double, float32: Bool,
              gen: (Double) -> (Double, Double)) {
    let frames = Int(Double(rate) * seconds)
    let ch = 2
    let bps = float32 ? 4 : 2
    var hdr = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { hdr.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { hdr.append(contentsOf: $0) } }
    let dataLen = frames * ch * bps
    hdr.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataLen)); hdr.append("WAVE".data(using: .ascii)!)
    hdr.append("fmt ".data(using: .ascii)!); u32(16); u16(float32 ? 3 : 1); u16(UInt16(ch))
    u32(UInt32(rate)); u32(UInt32(rate * ch * bps)); u16(UInt16(ch * bps)); u16(UInt16(bps * 8))
    hdr.append("data".data(using: .ascii)!); u32(UInt32(dataLen))
    var body = Data(count: dataLen)
    body.withUnsafeMutableBytes { raw in
        if float32 {
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<frames {
                let (l, r) = gen(Double(i) / Double(rate))
                p[2*i] = Float(l); p[2*i+1] = Float(r)
            }
        } else {
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let (l, r) = gen(Double(i) / Double(rate))
                p[2*i] = Int16(clamping: Int((l * 32767).rounded()))
                p[2*i+1] = Int16(clamping: Int((r * 32767).rounded()))
            }
        }
    }
    FileManager.default.createFile(atPath: path, contents: hdr + body)
}

/// File A: 60 s, 44.1 kHz float32 stereo. L = 0.1*sin(1 kHz), R = ascending ramp -0.9..+0.9 (encodes position)
/// File B: 30 s, 48 kHz s16 stereo.    L = 0.1*sin(440 Hz), R = descending ramp +0.9..-0.9
func generateTestFiles(dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    writeWav(path: dir + "/a.wav", rate: 44100, seconds: 60, float32: true) { t in
        (0.1 * sin(2 * .pi * 1000 * t), -0.9 + 1.8 * t / 60)
    }
    writeWav(path: dir + "/b.wav", rate: 48000, seconds: 30, float32: false) { t in
        (0.1 * sin(2 * .pi * 440 * t), 0.9 - 1.8 * t / 30)
    }
}
@inline(__always) func posA(_ r: Float) -> Double { (Double(r) + 0.9) / 1.8 * 60 }
@inline(__always) func posB(_ r: Float) -> Double { (0.9 - Double(r)) / 1.8 * 30 }

// MARK: - mpv wrapper (test-harness quality)

final class MPV: @unchecked Sendable {
    let h: OpaquePointer
    var eventThread: Thread?
    var onEvent: (@Sendable (String) -> Void)?

    init(options: [(String, String)], logLevel: String = "v") {
        setlocale(LC_NUMERIC, "C")
        guard let hh = mpv_create() else { fatalError("mpv_create failed") }
        h = hh
        for (k, v) in options {
            let r = mpv_set_option_string(h, k, v)
            if r < 0 { log("OPTION FAIL \(k)=\(v): \(String(cString: mpv_error_string(r)))") }
        }
        mpv_request_log_messages(h, logLevel)
        let r = mpv_initialize(h)
        if r < 0 { fatalError("mpv_initialize \(String(cString: mpv_error_string(r)))") }
    }

    func startEvents() {
        let h = self.h
        let th = Thread { [weak self] in
            while true {
                guard let ev = mpv_wait_event(h, 1.0) else { continue }
                let id = ev.pointee.event_id
                if id == MPV_EVENT_NONE { continue }
                if id == MPV_EVENT_SHUTDOWN { log("EVENT shutdown"); break }
                if id == MPV_EVENT_LOG_MESSAGE {
                    let m = ev.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let s = "\(String(cString: m.level)) \(String(cString: m.prefix)): \(String(cString: m.text))"
                        .trimmingCharacters(in: .newlines)
                    mpvlog(s)
                    let prefix = String(cString: m.prefix)
                    let lvl = String(cString: m.level)
                    if prefix.hasPrefix("ao") || prefix == "lavfi" || prefix.hasPrefix("af") || lvl == "error" || lvl == "warn" || lvl == "fatal" {
                        log("  mpv[\(lvl) \(prefix)] \(String(cString: m.text).trimmingCharacters(in: .newlines))")
                    }
                    continue
                }
                var desc = String(cString: mpv_event_name(id))
                if id == MPV_EVENT_END_FILE {
                    let e = ev.pointee.data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    desc += " reason=\(e.reason.rawValue) error=\(e.error)"
                }
                if id == MPV_EVENT_COMMAND_REPLY || id == MPV_EVENT_SET_PROPERTY_REPLY {
                    desc += " err=\(ev.pointee.error) ud=\(ev.pointee.reply_userdata)"
                }
                log("EVENT \(desc)")
                self?.onEvent?(desc)
            }
        }
        th.qualityOfService = .userInitiated
        th.start()
        eventThread = th
    }

    @discardableResult
    func command(_ args: [String]) -> (Int32, Double) {
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cargs.append(nil)
        let t = mono()
        let r = cargs.withUnsafeMutableBufferPointer { mpv_command(h, $0.baseAddress) }
        let dt = mono() - t
        for p in cargs { free(UnsafeMutablePointer(mutating: p)) }
        return (r, dt)
    }
    /// command, logged
    @discardableResult
    func cmd(_ args: String...) -> Int32 {
        let (r, dt) = command(args)
        log(String(format: "CMD %@ -> %d (%@) took %.1f ms", args.joined(separator: " "), r,
                   String(cString: mpv_error_string(r)), dt * 1000))
        return r
    }
    @discardableResult
    func set(_ name: String, _ value: String) -> Int32 {
        let t = mono()
        let r = mpv_set_property_string(h, name, value)
        log(String(format: "SET %@=%@ -> %d (%@) took %.1f ms", name, value, r, String(cString: mpv_error_string(r)), (mono() - t) * 1000))
        return r
    }
    func getDouble(_ name: String) -> (Double?, Double) {
        var v: Double = 0
        let t = mono()
        let r = mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &v)
        return (r >= 0 ? v : nil, mono() - t)
    }
    func getString(_ name: String) -> String? {
        guard let p = mpv_get_property_string(h, name) else { return nil }
        defer { mpv_free(p) }
        return String(cString: p)
    }
    func destroy() { mpv_terminate_destroy(h) }
}

// FIONREAD = _IOR('f', 127, int)
let FIONREAD_: UInt = 0x4004667F
func bytesInPipe(_ fd: Int32) -> Int {
    var n: Int32 = 0
    let r = ioctl(fd, FIONREAD_, &n)
    return r == 0 ? Int(n) : -1
}

func sleepUntil(_ t: Double) { // t in rel() seconds
    while true {
        let d = t - rel()
        if d <= 0 { return }
        usleep(UInt32(min(d, 0.05) * 1e6))
    }
}
