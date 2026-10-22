import Foundation
import Darwin

struct Tick {
    var t: Double          // rel time
    var bytesRead: Int     // bytes read from pipe this tick
    var fillFrames: Int    // ring fill after consume
    var consumed: Int      // frames consumed this tick
    var underrun: Int      // frames due but not available
    var rFirst: Float
    var rLast: Float
    var rmsL: Float        // RMS of left channel of consumed block
    var consuming: Bool
}

/// Models a real-time audio device pulling 48 kHz stereo float32 from a byte pipe.
/// Each 10 ms tick: (1) non-blocking read from the pipe into a byte ring with capacity `capFrames`,
/// (2) consume exactly the frames that elapsed in wall time (deficit = underrun, never caught up).
final class Consumer: @unchecked Sendable {
    let rate = 48000.0
    let frameBytes = 8
    var fd: Int32 = -1
    let path: String
    let capBytes: Int
    let buf: UnsafeMutableRawPointer
    var rpos = 0, wpos = 0
    let tick = 0.010

    let lock = NSLock()
    // control (under lock)
    var consuming = true
    var reading = true
    var flushReq = false
    var running = true
    var closeReq = false
    var discarding = false      // read+discard everything, output silence
    var absorb = false          // allow filling the ring up to full capacity (pause headroom)
    var targetFillBytes = Int.max
    var discardedBytes = 0
    // stats (under lock)
    var totalBytes = 0
    var totalConsumed = 0
    var totalUnderrun = 0
    var lastR: Float = .nan
    var gotData = false
    var inEOF = false
    var eofEvents: [Double] = []
    var resumeAfterEOF: [Double] = []
    var flushedBytes: [(Double, Int)] = []
    var drainedTotal = 0
    var timeline: [Tick] = []
    var thread: Thread?

    init(path: String, capFrames: Int) {
        self.path = path
        self.capBytes = capFrames * frameBytes
        buf = UnsafeMutableRawPointer.allocate(byteCount: capBytes, alignment: 16)
    }

    func openFIFO() {
        fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd < 0 { fatalError("open fifo \(errno)") }
    }

    var fillBytes: Int { wpos - rpos }

    private func readPipe() -> Int {
        var total = 0
        while true {
            let limit = absorb ? capBytes : min(capBytes, targetFillBytes)
            let space = limit - fillBytes
            if space <= 0 { break }
            let off = wpos % capBytes
            let contiguous = min(space, capBytes - off)
            let n = read(fd, buf + off, contiguous)
            if n > 0 {
                wpos += n; total += n
                if inEOF { inEOF = false; resumeAfterEOF.append(rel()) }
                gotData = true
                continue
            }
            if n == 0 {
                if gotData && !inEOF { inEOF = true; eofEvents.append(rel()) }
                break
            }
            break // EAGAIN or error
        }
        return total
    }

    private func drainDiscard() -> Int {
        var junk = [UInt8](repeating: 0, count: 65536)
        var total = 0
        while true {
            let n = junk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 65536) }
            if n > 0 { total += n } else { break }
        }
        return total
    }

    private var tmp = [Float](repeating: 0, count: 48000 * 2)

    /// consume n whole frames; returns (rFirst, rLast, rmsL)
    private func consume(_ n: Int) -> (Float, Float, Float) {
        if n == 0 { return (.nan, .nan, 0) }
        let bytes = n * frameBytes
        tmp.withUnsafeMutableBytes { dst in
            let off = rpos % capBytes
            let first = min(bytes, capBytes - off)
            memcpy(dst.baseAddress!, buf + off, first)
            if first < bytes { memcpy(dst.baseAddress! + first, buf, bytes - first) }
        }
        rpos += bytes
        var sumsq: Float = 0
        for i in 0..<n { let l = tmp[2*i]; sumsq += l * l }
        return (tmp[1], tmp[2*n-1], (sumsq / Float(n)).squareRoot())
    }

    func start() {
        let th = Thread { [self] in
            var last = mono()
            var next = last + tick
            var due = 0.0
            while true {
                lock.lock()
                if !running { lock.unlock(); break }
                if closeReq { closeReq = false; close(fd); fd = -1; reading = false }
                let doRead = reading && fd >= 0, doConsume = consuming
                if discarding && fd >= 0 { let k = drainDiscard() + fillBytes; drainedTotal += k - fillBytes; rpos = wpos; discardedBytes += k }
                if flushReq {
                    flushReq = false
                    let inRing = fillBytes
                    rpos = wpos
                    let drained = fd >= 0 ? drainDiscard() : 0
                    drainedTotal += drained
                    flushedBytes.append((rel(), inRing + drained))
                }
                lock.unlock()

                let br = doRead ? readPipe() : 0
                let nowT = mono(); let dt = nowT - last; last = nowT
                var take = 0, under = 0
                var rf: Float = .nan, rl: Float = .nan, rms: Float = 0
                if doConsume {
                    due += dt * rate
                    let want = Int(due); due -= Double(want)
                    let mis = (rpos + drainedTotal) % frameBytes
                    if mis != 0 && fillBytes >= frameBytes - mis { rpos += frameBytes - mis }
                    let avail = (rpos + drainedTotal) % frameBytes == 0 ? fillBytes / frameBytes : 0
                    take = min(want, avail); under = want - take
                    (rf, rl, rms) = consume(take)
                } else { due = 0 }

                lock.lock()
                totalBytes += br; totalConsumed += take; totalUnderrun += under
                if take > 0 { lastR = rl }
                timeline.append(Tick(t: rel(), bytesRead: br, fillFrames: fillBytes / frameBytes, consumed: take,
                                     underrun: under, rFirst: rf, rLast: rl, rmsL: rms, consuming: doConsume))
                lock.unlock()

                next += tick
                let s = next - mono()
                if s > 0 { usleep(UInt32(s * 1e6)) } else { next = mono() }
            }
        }
        th.qualityOfService = .userInteractive
        th.start()
        thread = th
    }

    func with<T>(_ f: (Consumer) -> T) -> T { lock.lock(); defer { lock.unlock() }; return f(self) }

    func dumpTimeline(_ path: String) {
        var s = "t,bytesRead,fill,consumed,underrun,rFirst,rLast,rmsL,consuming\n"
        with { c in
            for k in c.timeline {
                s += String(format: "%.4f,%d,%d,%d,%d,%.7f,%.7f,%.6f,%d\n", k.t, k.bytesRead, k.fillFrames, k.consumed,
                            k.underrun, k.rFirst, k.rLast, k.rmsL, k.consuming ? 1 : 0)
            }
        }
        FileManager.default.createFile(atPath: path, contents: s.data(using: .utf8))
    }
}
