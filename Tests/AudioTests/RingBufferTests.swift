// SPDX-License-Identifier: GPL-3.0-or-later
// The render bridge's visualiser ring (sa_render.c): an 8192-frame single-producer ring that always overwrites
// and a reader that copies the newest N frames ending `lag` before the write position. Test ideas adapted from
// hfyeomans/MacAmp @ cb0c77f `Tests/MacAmpTests/LockFreeRingBufferTests.swift` (write-then-read integrity,
// empty reads, overwrite keeps the newest data, wrap-around, many small writes then one large read, zero-length
// requests, a concurrent writer/reader stress run and a 48 kHz-rate run). MacAmp's ring is a FIFO with a read
// pointer and stereo frames; ours is a mono "newest window", so each idea is restated for that contract.
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
import Foundation
import Synchronization
import Testing
@testable import Audio

/// A bridge whose source writes the frame index into every sample, so ring contents are checkable exactly.
final class CounterBridge {
    let bridge = RenderBridge()
    private var left: [Float]
    private var right: [Float]

    init(maxChunk: Int = 4096) {
        bridge.setTestSignal(.counter)
        left = [Float](repeating: 0, count: maxChunk)
        right = [Float](repeating: 0, count: maxChunk)
    }

    func write(_ frames: Int) {
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                _ = bridge.process(left: l.baseAddress!, right: r.baseAddress!, frames: frames)
            }
        }
    }

    /// True if `window` is `count` consecutive frame indices ending at `end - 1`.
    static func isRun(_ window: [Float], endingBefore end: Int) -> Bool {
        window.enumerated().allSatisfy { $0.element == Float(end - window.count + $0.offset) }
    }
}

@Suite struct RingBufferTests {
    @Test func writeThenReadBackExactly() {
        let c = CounterBridge()
        c.write(512)
        #expect(c.bridge.ringFramesWritten == 512)
        let all = c.bridge.copyNewest(512)
        #expect(all.map { CounterBridge.isRun($0, endingBefore: 512) } == true)
    }

    @Test func emptyRingRefusesReads() {
        let c = CounterBridge()
        #expect(c.bridge.copyNewest(1) == nil)
        c.write(10)
        #expect(c.bridge.copyNewest(11) == nil)
        #expect(c.bridge.copyNewest(10, lagFrames: 1) == nil)
        #expect(c.bridge.copyNewest(9, lagFrames: 1).map { CounterBridge.isRun($0, endingBefore: 9) } == true)
    }

    @Test func zeroAndInvalidRequestsAreRefused() {
        let c = CounterBridge()
        c.write(4096)
        #expect(c.bridge.copyNewest(0) == nil)
        #expect(c.bridge.copyNewest(16, lagFrames: -1) == nil)
        // The reader keeps clear of a callback in progress: count + lag must leave a 4096-frame guard.
        #expect(c.bridge.copyNewest(4096) != nil)
        #expect(c.bridge.copyNewest(4097) == nil)
        #expect(c.bridge.copyNewest(2048, lagFrames: 2049) == nil)
    }

    @Test func overwritingKeepsTheNewestFrames() {
        let c = CounterBridge()
        for _ in 0..<7 { c.write(4096) } // 28,672 frames: the 8192-frame ring wrapped three times
        let newest = c.bridge.copyNewest(4096)
        #expect(newest.map { CounterBridge.isRun($0, endingBefore: 28_672) } == true)
    }

    @Test func wrapAroundIsContiguous() {
        let c = CounterBridge()
        c.write(4096)
        c.write(4000) // 8096 written
        c.write(300)  // straddles the 8192 boundary
        let window = c.bridge.copyNewest(1000, lagFrames: 50)
        #expect(window.map { CounterBridge.isRun($0, endingBefore: 8396 - 50) } == true)
    }

    @Test func manySmallWritesThenOneLargeRead() {
        let c = CounterBridge()
        for _ in 0..<40 { c.write(100) }
        #expect(c.bridge.ringFramesWritten == 4000)
        #expect(c.bridge.copyNewest(4000).map { CounterBridge.isRun($0, endingBefore: 4000) } == true)
        let window = c.bridge.copyNewest(3900, lagFrames: 100)
        #expect(window.map { CounterBridge.isRun($0, endingBefore: 3900) } == true)
    }

    @Test func monoMixIsTheAverageOfTheChannels() {
        let bridge = RenderBridge()
        bridge.setTestSignal(.sine(frequency: 1000, amplitude: 0.8, rightAmplitude: 0.2))
        var l = [Float](repeating: 0, count: 480), r = [Float](repeating: 0, count: 480)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in _ = bridge.process(left: lb.baseAddress!, right: rb.baseAddress!, frames: 480) }
        }
        let mono = bridge.copyNewest(480)!
        for i in 0..<480 { #expect(abs(mono[i] - 0.5 * (l[i] + r[i])) < 1e-7) }
    }

    final class StressState: Sendable {
        let done = Atomic<Bool>(false)
        let reads = Atomic<Int>(0)
        let torn = Atomic<Int>(0)
    }

    /// MacAmp's concurrent writer/reader idea, made strict: every successful copy must be a run of consecutive
    /// frame indices (no torn reads), while the writer laps the ring continuously.
    @Test(.timeLimit(.minutes(1))) func concurrentReaderNeverSeesTornData() async {
        let bridge = RenderBridge()
        bridge.setTestSignal(.counter)
        let state = StressState()
        let writer = Thread {
            // 30,000 callbacks of 512 frames = 15.4 M frames (counter values stay exact in Float below 2^24).
            var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
            for _ in 0..<30_000 {
                l.withUnsafeMutableBufferPointer { lb in
                    r.withUnsafeMutableBufferPointer { rb in
                        _ = bridge.process(left: lb.baseAddress!, right: rb.baseAddress!, frames: 512)
                    }
                }
            }
            state.done.store(true, ordering: .releasing)
        }
        let reader = Thread {
            var window = [Float](repeating: 0, count: 1024)
            while !state.done.load(ordering: .acquiring) {
                let ok = window.withUnsafeMutableBufferPointer { bridge.copyNewest(into: $0, lagFrames: 576) }
                guard ok else { continue }
                state.reads.add(1, ordering: .relaxed)
                for i in 1..<window.count where window[i] != window[i - 1] + 1 {
                    state.torn.add(1, ordering: .relaxed)
                    break
                }
            }
        }
        writer.start()
        reader.start()
        while !state.done.load(ordering: .acquiring) { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(state.reads.load(ordering: .relaxed) > 100)
        #expect(state.torn.load(ordering: .relaxed) == 0)
        #expect(bridge.ringFramesWritten == 30_000 * 512)
    }

    /// MacAmp's 48 kHz throughput idea: a writer paced like the IO thread and a 30 Hz reader always get the
    /// window that ends at the current write position minus the lag.
    @Test(.timeLimit(.minutes(1))) func pacedWriterAndReaderAgree() {
        let c = CounterBridge(maxChunk: 512)
        var ok = 0, attempts = 0
        for k in 1...300 {
            c.write(512) // one 10.67 ms callback
            if k % 3 == 0 {
                let w = c.bridge.copyNewest(1024, lagFrames: 576)
                // 1024 + 576 frames of history exist from the 4th callback on.
                #expect((w == nil) == (k * 512 < 1600))
                guard let w else { continue }
                attempts += 1
                if CounterBridge.isRun(w, endingBefore: k * 512 - 576) { ok += 1 }
            }
        }
        #expect(attempts == 99 && ok == attempts)
    }
}
