// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Testing
@testable import Audio

/// Polls `condition` every 10 ms for up to `timeout` seconds.
func eventually(_ timeout: Double = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite struct OfflineGraphTests {
    @Test func offlineGraphRendersTheBridgeThroughEQAndMixer() throws {
        let engine = try AudioEngine(volume: 100, renderingMode: .offline(maximumFrameCount: 2048))
        #expect(engine.manualRenderingFormat.sampleRate == 48_000 && engine.manualRenderingFormat.channelCount == 2)
        #expect(engine.presentationLatency == 0 && engine.outputDevice == nil)
        engine.bridge.setTestSignal(.sine(frequency: 1000, amplitude: 0.25))
        try engine.start()
        #expect(engine.isRunning)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2048))
        #expect(try engine.renderOffline(2048, to: buffer) == .success)
        let peak = (0..<2048).reduce(Float(0)) { max($0, abs(buffer.floatChannelData![0][$1])) }
        #expect(abs(peak - 0.25) < 0.01)
        #expect(engine.bridge.ringFramesWritten == 2048)
        // Without a test signal the bridge pulls the (absent) AO: silence (once the EQ's tail has decayed),
        // counted as unavailable.
        engine.bridge.setTestSignal(nil)
        _ = try engine.renderOffline(2048, to: buffer)
        _ = try engine.renderOffline(512, to: buffer)
        #expect((0..<512).allSatisfy { abs(buffer.floatChannelData![0][$0]) < 1e-6 })
        #expect(engine.bridge.copyNewest(512) == [Float](repeating: 0, count: 512))
        #expect(engine.bridge.counters.aoUnavailable >= 1)
        engine.stop()
    }

    @Test func balanceFullLeftSilencesTheRightChannel() throws {
        let engine = try AudioEngine(volume: 100, renderingMode: .offline(maximumFrameCount: 4096))
        engine.bridge.setTestSignal(.sine(frequency: 1000, amplitude: 0.5))
        engine.setBalance(-1)
        #expect(engine.balance == -1)
        try engine.start()
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        for _ in 0..<3 { _ = try engine.renderOffline(4096, to: buffer) }
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 4096))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: 4096))
        let l = EQMeasurement.amplitude(left, frequency: 1000), r = EQMeasurement.amplitude(right, frequency: 1000)
        #expect(abs(20 * log10(l / 0.5)) < 0.05)
        #expect(r == 0 || 20 * log10(r / 0.5) <= -60)
        engine.setBalance(.nan)
        #expect(engine.balance == 0)
        engine.setBalance(5)
        #expect(engine.balance == 1)
    }
}

@Suite struct IdleStopTests {
    @Test func stopsAfterTheDelayAndRestartsOnResume() async throws {
        let engine = try AudioEngine(volume: 0, renderingMode: .offline(maximumFrameCount: 512))
        try engine.start()
        #expect(!engine.isIdleStopped)
        engine.scheduleIdleStop(after: 0.05)
        #expect(engine.isRunning) // not yet
        #expect(await eventually { engine.isIdleStopped })
        #expect(!engine.isRunning)
        #expect(try engine.resumeFromIdleStop())
        #expect(engine.isRunning && !engine.isIdleStopped)
        #expect(try !engine.resumeFromIdleStop()) // nothing to restart
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        #expect(try engine.renderOffline(512, to: buffer) == .success)
    }

    @Test func cancelledOrSupersededStopsDoNothing() async throws {
        let engine = try AudioEngine(volume: 0, renderingMode: .offline(maximumFrameCount: 512))
        try engine.start()
        engine.scheduleIdleStop(after: 0.05)
        engine.cancelIdleStop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.isRunning && !engine.isIdleStopped)
        // A newer schedule replaces an older one; resuming (playback started again) cancels it.
        engine.scheduleIdleStop(after: 0.05)
        engine.scheduleIdleStop(after: 10)
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.isRunning)
        #expect(try !engine.resumeFromIdleStop())
        // An explicit stop is not an idle stop.
        engine.scheduleIdleStop(after: 0.05)
        engine.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!engine.isRunning && !engine.isIdleStopped)
    }

    @Test func idleStopNowIsAnIdleStop() throws {
        let engine = try AudioEngine(volume: 0, renderingMode: .offline(maximumFrameCount: 512))
        try engine.start()
        engine.scheduleIdleStop(after: 30)
        engine.idleStopNow()
        #expect(engine.isIdleStopped && !engine.isRunning)
        engine.idleStopNow() // idempotent
        #expect(try engine.resumeFromIdleStop() && engine.isRunning)
    }

    @Test func defaultDelayIsThirtySeconds() {
        #expect(AudioEngine.idleStopDelay == 30)
    }
}

@Suite struct RecoveryPolicyTests {
    @Test func selfInflictedChangesUseTheShortWindow() {
        let start: UInt64 = 10_000_000_000
        let short = AudioEngine.selfInflictedDebounceInterval
        let normal = AudioEngine.debounceInterval
        #expect(AudioEngine.debounce(for: .configurationChange, now: start + 300_000_000, lastOwnStart: start) == short)
        #expect(AudioEngine.debounce(for: .configurationChange, now: start + 2_000_000_000, lastOwnStart: start) == normal)
        #expect(AudioEngine.debounce(for: .configurationChange, now: start, lastOwnStart: 0) == normal)
        #expect(AudioEngine.debounce(for: .defaultOutput, now: start + 1, lastOwnStart: start) == normal)
        #expect(AudioEngine.debounce(for: .recheck, now: start, lastOwnStart: 0) == short)
        #expect(normal == 0.150 && short == 0.010)
    }

    @Test func offlineEnginesIgnoreDeviceFollowing() throws {
        let engine = try AudioEngine(volume: 0, renderingMode: .offline(maximumFrameCount: 512))
        engine.setFollowsDefaultOutput(true) // no HAL listener for an offline engine
        #expect(engine.configurationStats == ConfigurationStats())
    }
}
