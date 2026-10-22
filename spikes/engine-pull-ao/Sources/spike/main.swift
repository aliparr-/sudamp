import Foundation
import Darwin
import Libmpv

let BASE = "/tmp/sudamp-spike/engine"
let MEDIA = BASE + "/media"

func prepRunDir(_ tag: String) -> String {
    let dir = BASE + "/run-" + tag
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir + "/log.txt", contents: nil)
    FileManager.default.createFile(atPath: dir + "/mpv.log", contents: nil)
    logFH = FileHandle(forWritingAtPath: dir + "/log.txt")
    mpvLogFH = FileHandle(forWritingAtPath: dir + "/mpv.log")
    T0 = mono()
    return dir
}

func pcmOptions(fifo: String, extra: [(String, String)] = []) -> [(String, String)] {
    [("vid", "no"), ("audio-display", "no"), ("ao", "pcm"), ("ao-pcm-file", fifo), ("ao-pcm-waveheader", "no"),
     ("audio-format", "float"), ("audio-samplerate", "48000"), ("audio-channels", "stereo")] + extra
}

// Monitor thread: samples time-pos every 100 ms, records call latency and consumer state.
final class Monitor: @unchecked Sendable {
    var rows: [String] = ["t,latency_ms,timepos,lastR,fill,pipeBytes,totalBytes,totalConsumed,totalUnderrun"]
    var running = true
    let lock = NSLock()
    func start(mpv: MPV, c: Consumer) {
        let th = Thread { [self] in
            while true {
                lock.lock(); let go = running; lock.unlock()
                if !go { break }
                let t = rel()
                let (tp, lat) = mpv.getDouble("time-pos")
                let s = c.with { c in (c.lastR, c.fillBytes / 8, c.fd >= 0 ? bytesInPipe(c.fd) : -1, c.totalBytes, c.totalConsumed, c.totalUnderrun) }
                let row = String(format: "%.4f,%.2f,%@,%.7f,%d,%d,%d,%d,%d", t, lat * 1000, tp.map { String(format: "%.4f", $0) } ?? "nan",
                                 s.0, s.1, s.2, s.3, s.4, s.5)
                lock.lock(); rows.append(row); lock.unlock()
                usleep(100_000)
            }
        }
        th.start()
    }
    func stop(dump path: String) {
        lock.lock(); running = false; let r = rows; lock.unlock()
        usleep(300_000)
        FileManager.default.createFile(atPath: path, contents: (r.joined(separator: "\n") + "\n").data(using: .utf8))
    }
}

func pipeCapacity() {
    // anonymous pipe
    var fds: [Int32] = [0, 0]
    pipe(&fds)
    _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
    var total = 0
    let chunk = [UInt8](repeating: 1, count: 1024)
    while true { let n = chunk.withUnsafeBytes { write(fds[1], $0.baseAddress, 1024) }; if n <= 0 { break }; total += n }
    print("anon pipe capacity, 1 KiB writes: \(total) bytes")
    close(fds[0]); close(fds[1])
    pipe(&fds)
    _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
    total = 0
    let big = [UInt8](repeating: 1, count: 1 << 20)
    while true { let n = big.withUnsafeBytes { write(fds[1], $0.baseAddress, 1 << 20) }; if n <= 0 { break }; total += n }
    print("anon pipe capacity, 1 MiB writes: \(total) bytes")
    close(fds[0]); close(fds[1])
    // FIFO
    let p = BASE + "/captest.fifo"
    unlink(p); mkfifo(p, 0o600)
    let r = open(p, O_RDONLY | O_NONBLOCK)
    let w = open(p, O_WRONLY | O_NONBLOCK)
    total = 0
    while true { let n = big.withUnsafeBytes { write(w, $0.baseAddress, 1 << 20) }; if n <= 0 { break }; total += n }
    print("FIFO capacity, 1 MiB writes: \(total) bytes  (FIONREAD on reader: \(bytesInPipe(r)))")
    // blocking FIFO writer, stdio like mpv
    close(w); close(r); unlink(p)
    var st = stat()
    mkfifo(p, 0o600)
    let r2 = open(p, O_RDONLY | O_NONBLOCK)
    let f = fopen(p, "wb")!
    fstat(fileno(f), &st)
    print("FIFO st_blksize (stdio buffer size basis): \(st.st_blksize)")
    fclose(f); close(r2); unlink(p)
}

// MARK: - Q1 scenario: ao=pcm -> FIFO -> real-time consumer
func runPipeScenario(capFrames: Int, tag: String) {
    signal(SIGPIPE, SIG_IGN)
    let dir = prepRunDir(tag)
    let fifo = dir + "/audio.fifo"
    unlink(fifo); mkfifo(fifo, 0o600)
    let c = Consumer(path: fifo, capFrames: capFrames)
    c.openFIFO(); c.start()
    log("consumer ring = \(capFrames) frames (\(Double(capFrames) / 48.0) ms)")
    let mpv = MPV(options: pcmOptions(fifo: fifo))
    let armLock = NSLock(); nonisolated(unsafe) var armed: String? = nil
    mpv.onEvent = { desc in
        armLock.lock(); let a = armed; if let a, desc.hasPrefix(a) { armed = nil }; armLock.unlock()
        if let a, desc.hasPrefix(a) { c.with { $0.flushReq = true }; log("FLUSH on \(a)") }
    }
    func arm(_ e: String) { armLock.lock(); armed = e; armLock.unlock() }
    mpv.startEvents()
    let mon = Monitor(); mon.start(mpv: mpv, c: c)

    sleepUntil(0.5); mpv.cmd("loadfile", MEDIA + "/a.wav")
    sleepUntil(25); log("== pause (mpv only, consumer keeps pulling)"); mpv.set("pause", "yes")
    sleepUntil(28); mpv.set("pause", "no")
    sleepUntil(33); log("== pause (consumer stops first, then sync mpv pause from a side thread)"); c.with { $0.consuming = false }
    let pt = Thread { mpv.set("pause", "yes") }; pt.start()
    sleepUntil(36); log("consumer resumes pulling"); c.with { $0.consuming = true }
    sleepUntil(36.5); mpv.set("pause", "no")
    sleepUntil(40); log("== seek 10 absolute, no flush"); mpv.cmd("seek", "10", "absolute")
    sleepUntil(46); log("== seek 40 absolute, flush right after command"); mpv.cmd("seek", "40", "absolute"); c.with { $0.flushReq = true }
    sleepUntil(52); log("== seek 10 absolute, flush on playback-restart"); arm("playback-restart"); mpv.cmd("seek", "10", "absolute")
    sleepUntil(58); log("== seek 40 absolute, flush on seek event"); arm("seek"); mpv.cmd("seek", "40", "absolute")
    sleepUntil(64); log("== loadfile b.wav replace, flush on end-file"); arm("end-file"); mpv.cmd("loadfile", MEDIA + "/b.wav", "replace")
    sleepUntil(70); log("== consumer stops reading the pipe (stuck reader) for 5 s"); c.with { $0.reading = false }
    sleepUntil(72); Thread { mpv.set("volume", "90") }.start()
    sleepUntil(73); Thread { let (tp, lat) = mpv.getDouble("time-pos"); log(String(format: "get time-pos issued during stuck reader took %.1f ms (%@)", lat * 1000, tp.map { "\($0)" } ?? "nil")) }.start()
    sleepUntil(75); c.with { $0.reading = true }; log("consumer reading again")
    // wait for EOF of b.wav
    var waited = 0.0
    while waited < 60 {
        if mpv.getString("idle-active") == "yes" { break }
        usleep(250_000); waited += 0.25
    }
    log("idle-active=yes after b.wav; ao still open? audio-params=\(mpv.getString("audio-params") ?? "nil")")
    let tIdle = rel()
    sleepUntil(tIdle + 3)
    log("== loadfile a.wav then reader closes FIFO at +4 s (SIGPIPE ignored)")
    mpv.cmd("loadfile", MEDIA + "/a.wav")
    sleepUntil(tIdle + 7)
    var ru0 = rusage(); getrusage(RUSAGE_SELF, &ru0)
    let tp0 = mpv.getDouble("time-pos").0
    c.with { $0.closeReq = true }
    sleepUntil(tIdle + 10)
    var ru1 = rusage(); getrusage(RUSAGE_SELF, &ru1)
    let tp1 = mpv.getDouble("time-pos").0
    let cpu = (Double(ru1.ru_utime.tv_sec - ru0.ru_utime.tv_sec) + Double(ru1.ru_utime.tv_usec - ru0.ru_utime.tv_usec) / 1e6)
    log(String(format: "after reader close: 3 s wall, user CPU %.2f s, time-pos %@ -> %@, idle=%@", cpu,
               tp0.map { "\($0)" } ?? "nil", tp1.map { "\($0)" } ?? "nil", mpv.getString("idle-active") ?? "?"))
    mon.stop(dump: dir + "/monitor.csv")
    c.with { c in c.running = false }
    usleep(200_000)
    c.dumpTimeline(dir + "/ticks.csv")
    c.with { c in log("EOF events on FIFO: \(c.eofEvents.map { String(format: "%.3f", $0) }), resumed after EOF: \(c.resumeAfterEOF.map { String(format: "%.3f", $0) }), flushes: \(c.flushedBytes.map { String(format: "%.3f:%d B", $0.0, $0.1) })") }
    mpv.destroy()
    log("done")
}


// Best-case strategies for the FIFO path: discard-until-event for seek/skip, headroom ring for pause.
func runPipeBest(tag: String) {
    signal(SIGPIPE, SIG_IGN)
    let dir = prepRunDir(tag)
    let fifo = dir + "/audio.fifo"
    unlink(fifo); mkfifo(fifo, 0o600)
    let c = Consumer(path: fifo, capFrames: 48000 * 3)        // 3 s capacity
    c.targetFillBytes = 4800 * 8                                // normally keep only 100 ms
    c.openFIFO(); c.start()
    let mpv = MPV(options: pcmOptions(fifo: fifo))
    let armLock = NSLock(); nonisolated(unsafe) var armed: String? = nil
    mpv.onEvent = { desc in
        armLock.lock(); let a = armed; if let a, desc.hasPrefix(a) { armed = nil }; armLock.unlock()
        if let a, desc.hasPrefix(a) { c.with { $0.discarding = false }; log("STOP DISCARDING on \(a)") }
    }
    func arm(_ e: String) { armLock.lock(); armed = e; armLock.unlock() }
    mpv.startEvents()
    let mon = Monitor(); mon.start(mpv: mpv, c: c)
    sleepUntil(0.5); mpv.cmd("loadfile", MEDIA + "/a.wav")
    sleepUntil(8); log("== seek 40, discard until seek event"); arm("seek"); c.with { $0.discarding = true }; mpv.cmd("seek", "40", "absolute")
    sleepUntil(14); log("== seek 10, discard until seek event"); arm("seek"); c.with { $0.discarding = true }; mpv.cmd("seek", "10", "absolute")
    sleepUntil(20); log("== loadfile b, discard until end-file"); arm("end-file"); c.with { $0.discarding = true }; mpv.cmd("loadfile", MEDIA + "/b.wav", "replace")
    sleepUntil(26); log("== pause: consumer stops, ring may absorb up to 3 s, sync mpv pause"); c.with { $0.consuming = false; $0.absorb = true }; mpv.set("pause", "yes")
    sleepUntil(29); log("== resume"); mpv.set("pause", "no"); c.with { $0.consuming = true; $0.absorb = false }
    sleepUntil(34)
    mon.stop(dump: dir + "/monitor.csv")
    c.with { $0.running = false }
    usleep(200_000)
    c.dumpTimeline(dir + "/ticks.csv")
    c.with { c in log("discarded bytes total: \(c.discardedBytes)") }
    mpv.destroy()
}

func runDevFd() {
    signal(SIGPIPE, SIG_IGN)
    _ = prepRunDir("devfd")
    var fds: [Int32] = [0, 0]
    pipe(&fds)
    _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
    let mpv = MPV(options: pcmOptions(fifo: "/dev/fd/\(fds[1])"))
    mpv.startEvents()
    mpv.cmd("loadfile", MEDIA + "/a.wav")
    var total = 0
    let start = rel()
    var b = [UInt8](repeating: 0, count: 4096)
    while rel() - start < 3 {
        // read at real-time pace: 384000 B/s
        let target = Int((rel() - start) * 384000)
        while total < target {
            let n = b.withUnsafeMutableBytes { read(fds[0], $0.baseAddress, min(4096, target - total)) }
            if n <= 0 { break }; total += n
        }
        usleep(10_000)
    }
    log("devfd: read \(total) bytes in 3 s via /dev/fd/\(fds[1]); time-pos=\(mpv.getDouble("time-pos").0 ?? -1)")
    mpv.destroy()
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "gen": generateTestFiles(dir: MEDIA); print("generated in \(MEDIA)")
case "pipecap": pipeCapacity()
case "pipe": runPipeScenario(capFrames: Int(args[2])!, tag: args[3])
case "devfd": runDevFd()
case "pipebest": runPipeBest(tag: args[2])
case "eq": runEQ(ao: args.count > 2 ? args[2] : "pcm")
case "engine": runEngine(tag: args.count > 2 ? args[2] : "engine")
default: print("modes: gen | pipecap | pipe <capFrames> <tag> | devfd | eq [pcm|null] | engine")
}
