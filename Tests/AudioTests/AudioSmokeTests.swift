// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Testing
@testable import Audio

@Suite struct VolumeAndEQTests {
    @Test func volumeCurveIsSquareLaw() {
        #expect(AudioEngine.mixerVolume(forVolume: 0) == 0)
        #expect(AudioEngine.mixerVolume(forVolume: 100) == 1)
        #expect(abs(AudioEngine.mixerVolume(forVolume: 50) - 0.25) < 1e-6)
        #expect(abs(AudioEngine.mixerVolume(forVolume: 10) - 0.01) < 1e-6)
        #expect(AudioEngine.mixerVolume(forVolume: -5) == 0)
        #expect(AudioEngine.mixerVolume(forVolume: 250) == 1)
        #expect(AudioEngine.mixerVolume(forVolume: .nan) == 0)
    }

    @Test func eqIsTenFlatParametricOctaveBands() {
        let eq = AudioEngine.makeEQ()
        #expect(eq.bands.map(\.frequency) == AudioEngine.eqFrequencies)
        #expect(eq.bands.allSatisfy { $0.filterType == .parametric && $0.bandwidth == 1 && $0.gain == 0 && !$0.bypass })
        #expect(eq.globalGain == 0 && !eq.bypass)
    }

    @Test func balanceGains() {
        #expect(RenderBridge.channelGains(balance: 0) == (1, 1))
        #expect(RenderBridge.channelGains(balance: -1) == (1, 0))
        #expect(RenderBridge.channelGains(balance: 1) == (0, 1))
        let half = RenderBridge.channelGains(balance: 0.5)
        #expect(half.left == 0.5 && half.right == 1)
        #expect(RenderBridge.channelGains(balance: 7) == (0, 1))
    }
}

@Suite struct GraphTests {
    @Test func graphIsSourceToEQToMixerAndSilentAtVolumeZero() throws {
        let engine = try AudioEngine(volume: 0)
        let av = engine.avEngine
        let fromSource = av.outputConnectionPoints(for: engine.bridge.sourceNode, outputBus: 0)
        #expect(fromSource.first?.node === engine.eq)
        let fromEQ = av.outputConnectionPoints(for: engine.eq, outputBus: 0)
        #expect(fromEQ.first?.node === av.mainMixerNode)
        #expect(engine.bridge.format.sampleRate == 48000 && engine.bridge.format.channelCount == 2)
        #expect(!engine.bridge.format.isInterleaved)
        #expect(engine.mixerOutputVolume == 0)
        engine.setVolume(50)
        #expect(abs(engine.mixerOutputVolume - 0.25) < 1e-6)
        engine.setEQBand(4, gain: 40)
        #expect(engine.eqBandGains[4] == 12)
        engine.setPreamp(-40)
        #expect(engine.eq.globalGain == -12)
        #expect(!engine.isRunning)
    }
}

/// Drives the C render body directly with a synthetic source (no device, no mpv).
@Suite struct RenderBodyTests {
    final class Harness {
        let bridge = RenderBridge()
        let source: SyntheticSource
        var left = [Float](repeating: 9, count: 512)
        var right = [Float](repeating: 9, count: 512)

        init(left: Float = 0.5, right: Float = 0.25) {
            source = SyntheticSource(left: left, right: right)
            bridge.setSyntheticSource(source)
        }

        @discardableResult
        func render(_ frames: Int = 512) -> Bool {
            if left.count < frames {
                left = [Float](repeating: 9, count: frames)
                right = [Float](repeating: 9, count: frames)
            }
            return left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    bridge.process(left: l.baseAddress!, right: r.baseAddress!, frames: frames)
                }
            }
        }
    }

    @Test func passesSourceThroughAndPassesDelay() {
        let h = Harness()
        h.bridge.setLatency(seconds: 0.012)
        let silent = h.render()
        #expect(!silent)
        #expect(h.left.allSatisfy { $0 == 0.5 } && h.right.allSatisfy { $0 == 0.25 })
        // delay = latency + frames/48000 (ao_read_data wants the time the last sample plays).
        #expect(h.source.lastDelayNanos == 12_000_000 + 512 * 1_000_000_000 / 48000)
        let c = h.bridge.counters
        #expect(c.callbacks == 1 && c.frames == 512 && c.shortReads == 0 && c.silentCallbacks == 0)
    }

    @Test func hostPauseRampsOutWithinFiveMillisecondsThenStopsReading() {
        let h = Harness()
        h.render()
        h.bridge.setHostPaused(true)
        h.render()
        let ramp = RenderBridge.pauseRampFrames
        #expect(h.source.lastRequested == ramp) // only what the ramp consumes leaves mpv's queue
        #expect(h.left[0] < 0.5 && h.left[0] > 0.49)
        #expect(h.left[ramp / 2] > 0.2 && h.left[ramp / 2] < 0.3)
        #expect(h.left[ramp...].allSatisfy { $0 == 0 })
        let readsBefore = h.source.reads
        let silent = h.render()
        #expect(silent && h.left.allSatisfy { $0 == 0 })
        #expect(h.source.reads == readsBefore) // no read while paused
        #expect(h.bridge.counters.hostPausedCallbacks == 1)
        h.bridge.setHostPaused(false)
        h.render()
        #expect(h.left[0] > 0 && h.left[0] < 0.01) // ramps back in
        #expect(h.left[ramp + 1] == 0.5)
    }

    @Test func resumeRampWaitsForDeliveredAudioAndPauseSettles() {
        let h = Harness()
        h.render()
        h.bridge.setHostPaused(true)
        #expect(!h.bridge.isHostPauseSettled)
        h.render() // renders the 5 ms ramp
        #expect(h.bridge.isHostPauseSettled)
        h.bridge.setHostPaused(false)
        h.source.unavailable = true // mpv hasn't resumed streaming yet
        h.render()
        #expect(!h.bridge.isHostPauseSettled)
        h.source.unavailable = false
        h.render()
        #expect(h.left[0] > 0 && h.left[0] < 0.01) // the ramp starts with the first delivered frame
    }

    @Test func fadeInIsLinearOverDeliveredFrames() {
        let h = Harness(left: 1, right: 1)
        h.bridge.fadeIn(seconds: 0.1) // 4800 frames
        h.render(480)
        #expect(h.left[0] == 0)
        #expect(abs(h.left[479] - 479.0 / 4800) < 1e-4)
        // Frames the source didn't deliver don't advance the fade.
        h.source.maxFrames = 0
        h.source.unavailable = true
        h.render(480)
        h.source.unavailable = false
        h.render(480)
        #expect(abs(h.left[0] - 480.0 / 4800) < 1e-4)
        for _ in 0..<10 { h.render(480) }
        #expect(h.left[479] == 1)
    }

    @Test func balanceGainsInterpolateAcrossOneCallback() {
        let h = Harness(left: 1, right: 1)
        h.bridge.setBalance(-1) // left only
        h.render(256)
        #expect(abs(h.right[255]) < 1e-6 && h.right[0] > 0.99)
        h.render(256)
        #expect(h.right.prefix(256).allSatisfy { $0 == 0 } && h.left.prefix(256).allSatisfy { $0 == 1 })
    }

    @Test func countsShortReadsSilenceAndUnavailableAO() {
        let h = Harness()
        h.source.maxFrames = 100
        h.render()
        #expect(h.bridge.counters.shortReads == 1)
        #expect(h.left[99] == 0.5 && h.left[100] == 0)
        h.source.unavailable = true
        let silent = h.render()
        #expect(silent && h.right.allSatisfy { $0 == 0 })
        let c = h.bridge.counters
        #expect(c.aoUnavailable == 1 && c.silentCallbacks == 1 && c.callbacks == 2)
    }

    @Test func notStreamingShortReadIsNotAnUnderrun() {
        let h = Harness()
        h.source.state.pointee.streaming = false
        h.source.maxFrames = 1
        h.render()
        #expect(h.bridge.counters.shortReads == 0)
    }

    @Test func ttfaStampsFirstNonSilentCallbackAfterArm() {
        let h = Harness()
        h.source.unavailable = true
        h.bridge.armTTFA()
        h.render()
        #expect(h.bridge.ttfaNanos == nil)
        h.source.unavailable = false
        h.render()
        let first = h.bridge.ttfaNanos
        #expect(first != nil && first! >= h.bridge.ttfaArmedNanos)
        h.render()
        #expect(h.bridge.ttfaNanos == first) // only the first
        #expect(h.bridge.ttfaMilliseconds.map { $0 >= 0 } == true)
    }

    @Test func mutedOutputStillMeasures() {
        let h = Harness()
        h.bridge.setOutputMuted(true)
        h.bridge.armTTFA()
        h.bridge.enableProbe(capacity: 4)
        let silent = h.render()
        #expect(silent && h.left.allSatisfy { $0 == 0 })
        #expect(h.bridge.ttfaNanos != nil)
        let rec = h.bridge.probeRecords()
        #expect(rec.count == 1 && rec[0].peak == 0.5 && rec[0].got == 512 && rec[0].firstR == 0.25)
        #expect(h.bridge.copyNewest(512) == [Float](repeating: 0.375, count: 512))
    }

    @Test func probeStopsAtCapacity() {
        let h = Harness()
        #expect(h.bridge.enableProbe(capacity: 3))
        for _ in 0..<5 { h.render() }
        #expect(h.bridge.probeCount == 3)
        #expect(h.bridge.probeRecords(from: 1).count == 2)
    }
}

@Suite struct VisualiserRingTests {
    @Test func copiesNewestSamplesWithLagAcrossWrap() {
        let bridge = RenderBridge()
        let source = SyntheticSource(left: 0, right: 0)
        bridge.setSyntheticSource(source)
        var l = [Float](repeating: 0, count: 1000), r = [Float](repeating: 0, count: 1000)
        // Write 70 blocks of 1000 frames, block k carrying mono value k (wraps the 65,536-frame ring).
        for k in 0..<70 {
            source.state.pointee.left = Float(k)
            source.state.pointee.right = Float(k)
            l.withUnsafeMutableBufferPointer { lb in
                r.withUnsafeMutableBufferPointer { rb in
                    _ = bridge.process(left: lb.baseAddress!, right: rb.baseAddress!, frames: 1000)
                }
            }
        }
        #expect(bridge.ringFramesWritten == 70_000)
        let newest = bridge.copyNewest(1000)
        #expect(newest == [Float](repeating: 69, count: 1000))
        let lagged = bridge.copyNewest(1000, lagFrames: 1500)
        #expect(lagged.map { Array($0.prefix(500)) } == [Float](repeating: 67, count: 500))
        #expect(lagged.map { Array($0.suffix(500)) } == [Float](repeating: 68, count: 500))
        // Too much history requested: refused rather than torn.
        #expect(bridge.copyNewest(RenderBridge.ringFrames - RenderBridge.ringGuardFrames + 1) == nil)
        #expect(bridge.copyNewest(0) == nil)
    }

    @Test func refusesBeforeEnoughHistory() {
        let bridge = RenderBridge()
        bridge.setSyntheticSource(SyntheticSource(left: 1, right: 1))
        var l = [Float](repeating: 0, count: 100), r = [Float](repeating: 0, count: 100)
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in _ = bridge.process(left: lb.baseAddress!, right: rb.baseAddress!, frames: 100) }
        }
        #expect(bridge.copyNewest(101) == nil)
        #expect(bridge.copyNewest(100) == [Float](repeating: 1, count: 100))
    }
}
