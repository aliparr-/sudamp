// SPDX-License-Identifier: GPL-3.0-or-later
// Position-ramp generator ported from spikes/engine-pull-ao/Sources/spikepull/Common.swift (own code).
import Foundation

/// The position-encoding test WAV (PLAN M0 fixture; generated, never committed): 60 s, 44.1 kHz, stereo float32.
/// Left is a 0.1-amplitude 1 kHz sine (non-silent audio); right is a linear ramp from -0.9 to +0.9 that encodes
/// the playback position, so a rendered sample tells which second of the file it came from (seek/stale checks).
/// The 44.1 kHz rate makes mpv resample to the AO's 48 kHz, which the audio-out-params guard checks.
public enum RampFixture {
    public static let sampleRate = 44100
    public static let seconds = 60.0
    public static let rampLow: Float = -0.9
    public static let rampHigh: Float = 0.9
    /// Relative to the repository root (cwd of `swift run`, `make` and the gates).
    public static let defaultRelativePath = ".build/fixtures/ramp60.wav"

    /// Byte-for-byte deterministic WAV data.
    public static func wavData(sampleRate: Int = sampleRate, seconds: Double = seconds) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let channels = 2, bytesPerSample = 4
        let dataLength = frames * channels * bytesPerSample
        var data = Data(capacity: 44 + dataLength)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataLength)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(3) // WAVE_FORMAT_IEEE_FLOAT
        u16(UInt16(channels)); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * channels * bytesPerSample))
        u16(UInt16(channels * bytesPerSample)); u16(UInt16(bytesPerSample * 8))
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(dataLength))
        var body = [Float](repeating: 0, count: frames * channels)
        let span = Double(rampHigh - rampLow)
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            body[2 * i] = Float(0.1 * sin(2 * Double.pi * 1000 * t))
            body[2 * i + 1] = Float(Double(rampLow) + span * t / seconds)
        }
        body.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// Writes the fixture atomically.
    public static func write(to url: URL, sampleRate: Int = sampleRate, seconds: Double = seconds) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wavData(sampleRate: sampleRate, seconds: seconds).write(to: url, options: .atomic)
    }

    /// Returns `url`, generating the default fixture there first if it is missing or the wrong size.
    @discardableResult
    public static func ensure(at url: URL) throws -> URL {
        let expected = 44 + Int(Double(sampleRate) * seconds) * 8
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if size != expected { try write(to: url) }
        return url
    }

    /// Playback position in seconds encoded by a right-channel sample.
    public static func position(fromRight r: Float, seconds: Double = seconds) -> Double {
        (Double(r) - Double(rampLow)) / Double(rampHigh - rampLow) * seconds
    }
}
