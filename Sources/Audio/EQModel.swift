// SPDX-License-Identifier: GPL-3.0-or-later
// Pure EQ model (no AVFoundation): settings, headroom policy and the analytic response of the 10-band graph EQ.
import Foundation

/// What the 10-band EQ should do (DESIGN §5.4): on/off, preamp and band gains in dB, each clamped to ±12.
public struct EQSettings: Sendable, Equatable, Hashable, Codable {
    public static let bandCount = 10
    public static let gainRange: ClosedRange<Float> = -12...12

    public var enabled: Bool
    /// Preamp in dB (AVAudioUnitEQ `globalGain`).
    public var preamp: Float
    /// Gains in dB for the bands at `AudioEngine.eqFrequencies`, always exactly 10 values.
    public var bands: [Float]

    public init(enabled: Bool = true, preamp: Float = 0, bands: [Float] = Array(repeating: 0, count: EQSettings.bandCount)) {
        self.enabled = enabled
        self.preamp = Self.clamp(preamp)
        self.bands = Self.normalize(bands)
    }

    /// EQ on, preamp 0, every band 0 dB.
    public static let flat = EQSettings()

    public var isFlat: Bool { preamp == 0 && bands.allSatisfy { $0 == 0 } }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  preamp: try c.decodeIfPresent(Float.self, forKey: .preamp) ?? 0,
                  bands: try c.decodeIfPresent([Float].self, forKey: .bands) ?? [])
    }

    /// Clamps to ±12 dB; NaN becomes 0.
    public static func clamp(_ gain: Float) -> Float {
        gain.isNaN ? 0 : min(max(gain, gainRange.lowerBound), gainRange.upperBound)
    }

    /// Exactly `bandCount` clamped gains: extra values are dropped, missing ones are 0.
    static func normalize(_ bands: [Float]) -> [Float] {
        (0..<bandCount).map { $0 < bands.count ? clamp(bands[$0]) : 0 }
    }
}

/// How the engine keeps EQ boosts from driving the output into clipping (DESIGN §5.4; decision in
/// docs/spikes/M3-audio.md: AUPeakLimiter is not shipped, so combined boost is capped at +6 dB).
public enum EQHeadroom: Sendable, Equatable, Hashable, Codable {
    /// Apply the settings exactly (measurements only).
    case off
    /// Lower the applied preamp so that preamp + the EQ curve's peak never exceeds `maxBoostDB`. The band shape is
    /// kept; only the overall level drops, and only when needed.
    case cap(maxBoostDB: Float)

    public static let `default` = EQHeadroom.cap(maxBoostDB: 6)

    /// The `globalGain` actually applied for `settings`.
    public func appliedPreamp(for settings: EQSettings) -> Float {
        switch self {
        case .off:
            return settings.preamp
        case .cap(let maxBoost):
            let peak = Float(EQResponse.peakGainDB(bands: settings.bands))
            return max(min(settings.preamp, maxBoost - peak), -96)
        }
    }
}

/// Analytic magnitude response of the 10-band EQ: a cascade of RBJ "Audio EQ Cookbook" peaking biquads with the
/// bilinear-prewarped bandwidth `alpha = sin(w0)·sinh(ln2/2 · BW · w0/sin(w0))`. AVAudioUnitEQ's `.parametric`
/// band matched this to 0.001 dB at 21 test points (M3, docs/spikes/M3-audio.md), so the headroom cap can use it.
public enum EQResponse {
    public static let sampleRate = 48_000.0

    /// The band centres (Hz), one octave wide (`AudioEngine.eqFrequencies`).
    public static let frequencies: [Double] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]
    public static let bandwidthOctaves = 1.0

    /// Response in dB of one peaking band of `gainDB` centred on `centre`, at `frequency`.
    public static func bandGainDB(centre: Double, gainDB: Double, at frequency: Double,
                                  bandwidth: Double = bandwidthOctaves, sampleRate: Double = sampleRate) -> Double {
        guard gainDB != 0, centre > 0, centre < sampleRate / 2 else { return 0 }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * centre / sampleRate
        let alpha = sin(w0) * sinh(log(2) / 2 * bandwidth * w0 / sin(w0))
        let cw = -2 * cos(w0)
        let w = 2 * Double.pi * frequency / sampleRate
        func magnitude(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let im = -(c1 * sin(w) + c2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        return 20 * log10(magnitude(1 + alpha * a, cw, 1 - alpha * a) / magnitude(1 + alpha / a, cw, 1 - alpha / a))
    }

    /// Response in dB of the whole cascade (bands only; add the preamp for the total) at `frequency`.
    public static func gainDB(at frequency: Double, bands: [Float]) -> Double {
        zip(frequencies, bands).reduce(0) { $0 + bandGainDB(centre: $1.0, gainDB: Double($1.1), at: frequency) }
    }

    /// The highest response of the cascade over 20 Hz–20 kHz (a 1/48-octave grid plus every band centre), in dB.
    /// Never below the response at 20 Hz or 20 kHz, so all-cut settings report a value ≤ 0.
    public static func peakGainDB(bands: [Float]) -> Double {
        guard bands.contains(where: { $0 > 0 }) else {
            return bands.isEmpty ? 0 : max(gainDB(at: 20, bands: bands), gainDB(at: 20_000, bands: bands))
        }
        var peak = -Double.infinity
        for f in grid { peak = max(peak, gainDB(at: f, bands: bands)) }
        return peak
    }

    /// 20 Hz–20 kHz in 1/48-octave steps, plus the band centres (where single-band peaks sit exactly).
    static let grid: [Double] = {
        let steps = Int((log2(20_000.0 / 20.0) * 48).rounded(.up))
        return ((0...steps).map { 20 * pow(2, Double($0) / 48) }.filter { $0 <= 20_000 } + frequencies).sorted()
    }()
}
