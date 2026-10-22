// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Recognises a direct audio stream from its first bytes (`catalog-tool probe` and `discover` for radio, as in the
/// catalog seed: "at least 4 chained MPEG-audio or ADTS-AAC frames"). A stream that joins mid-frame is fine: the
/// sniffer looks for the longest chain of consecutive, length-consistent frames starting anywhere in the window.
public enum AudioSniffer {
    public enum Format: String, Sendable, Equatable {
        case mpeg
        case adts
        case ogg
    }

    public struct Match: Sendable, Equatable {
        public var format: Format
        /// Consecutive frames (Ogg: pages) whose lengths chain exactly.
        public var chained: Int
        /// Where the chain starts.
        public var offset: Int
        /// MPEG/ADTS sample rate of the first frame (0 for Ogg).
        public var sampleRate: Int
        /// MPEG bitrate in kbit/s of the first frame (0 when unknown).
        public var kbps: Int
    }

    /// The longest chain found in `data` (searching sync positions in the first `window` bytes), if it has at least
    /// `minimum` frames.
    public static func sniff(_ data: Data, minimum: Int = 4, window: Int = 16_384) -> Match? {
        let bytes = [UInt8](data)
        var best: Match?
        let limit = min(bytes.count, window)
        var i = 0
        while i < limit {
            if let m = chain(bytes, at: i), m.chained >= (best?.chained ?? 0) + 1 {
                best = m
                if m.chained >= 32 { break }
            }
            i += 1
        }
        guard let best, best.chained >= minimum else { return nil }
        return best
    }

    private static func chain(_ b: [UInt8], at start: Int) -> Match? {
        guard start + 4 <= b.count else { return nil }
        let kind: Format
        if b[start] == 0x4F, b[start + 1] == 0x67, b[start + 2] == 0x67, b[start + 3] == 0x53 { kind = .ogg }
        else if b[start] == 0xFF, b[start + 1] & 0xF6 == 0xF0 { kind = .adts }
        else if b[start] == 0xFF, b[start + 1] & 0xE0 == 0xE0 { kind = .mpeg }
        else { return nil }
        var pos = start, count = 0
        var first: (rate: Int, kbps: Int)?
        while let f = frame(kind, b, at: pos) {
            if first == nil { first = (f.rate, f.kbps) }
            count += 1
            pos += f.length
            if pos + 4 > b.count { break }
        }
        guard count > 0, let first else { return nil }
        return Match(format: kind, chained: count, offset: start, sampleRate: first.rate, kbps: first.kbps)
    }

    private static func frame(_ kind: Format, _ b: [UInt8], at i: Int) -> (length: Int, rate: Int, kbps: Int)? {
        switch kind {
        case .mpeg: mpegFrame(b, at: i)
        case .adts: adtsFrame(b, at: i)
        case .ogg: oggPage(b, at: i)
        }
    }

    // MARK: MPEG audio (ISO 11172-3 / 13818-3)

    private static let bitrates: [[Int]] = [
        [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],   // V1 L1
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],      // V1 L2
        [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],       // V1 L3
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],      // V2 L1
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],           // V2 L2/L3
    ]

    private static func mpegFrame(_ b: [UInt8], at i: Int) -> (length: Int, rate: Int, kbps: Int)? {
        guard i + 4 <= b.count, b[i] == 0xFF, b[i + 1] & 0xE0 == 0xE0 else { return nil }
        let version = (b[i + 1] >> 3) & 0x03      // 0: 2.5, 1: reserved, 2: 2, 3: 1
        let layer = (b[i + 1] >> 1) & 0x03        // 1: III, 2: II, 3: I
        let bitrateIndex = Int(b[i + 2] >> 4)
        let rateIndex = Int((b[i + 2] >> 2) & 0x03)
        let padding = Int((b[i + 2] >> 1) & 0x01)
        guard version != 1, layer != 0, bitrateIndex != 0, bitrateIndex != 15, rateIndex != 3 else { return nil }
        let v1 = version == 3
        let table = v1 ? (layer == 3 ? 0 : layer == 2 ? 1 : 2) : (layer == 3 ? 3 : 4)
        let kbps = bitrates[table][bitrateIndex]
        let baseRate = [44100, 48000, 32000][rateIndex]
        let rate = version == 3 ? baseRate : version == 2 ? baseRate / 2 : baseRate / 4
        let length: Int
        switch layer {
        case 3: length = (12 * kbps * 1000 / rate + padding) * 4
        case 2: length = 144 * kbps * 1000 / rate + padding
        default: length = (v1 ? 144 : 72) * kbps * 1000 / rate + padding
        }
        guard length >= 21 else { return nil }
        return (length, rate, kbps)
    }

    // MARK: ADTS (ISO 14496-3)

    private static func adtsFrame(_ b: [UInt8], at i: Int) -> (length: Int, rate: Int, kbps: Int)? {
        guard i + 7 <= b.count, b[i] == 0xFF, b[i + 1] & 0xF6 == 0xF0 else { return nil }
        let rateIndex = Int((b[i + 2] >> 2) & 0x0F)
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        guard rateIndex < rates.count else { return nil }
        let length = (Int(b[i + 3] & 0x03) << 11) | (Int(b[i + 4]) << 3) | (Int(b[i + 5]) >> 5)
        guard length >= 7 else { return nil }
        return (length, rates[rateIndex], 0)
    }

    // MARK: Ogg (RFC 3533)

    private static func oggPage(_ b: [UInt8], at i: Int) -> (length: Int, rate: Int, kbps: Int)? {
        guard i + 27 <= b.count, b[i] == 0x4F, b[i + 1] == 0x67, b[i + 2] == 0x67, b[i + 3] == 0x53, b[i + 4] == 0 else {
            return nil
        }
        let segments = Int(b[i + 26])
        guard i + 27 + segments <= b.count else { return nil }
        let body = b[(i + 27)..<(i + 27 + segments)].reduce(0) { $0 + Int($1) }
        return (27 + segments + body, 0, 0)
    }
}
