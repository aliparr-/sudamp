// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import MPV

/// `sudamp-dev gen-ramp [--out <path>] [--json]`: writes the deterministic 60 s, 44.1 kHz stereo float32
/// position-ramp WAV (default `.build/fixtures/ramp60.wav`; fixtures are generated, never committed).
enum GenRampCommand {
    struct Report: Encodable {
        var path: String
        var bytes: Int
        var sha256: String
        var sampleRate: Int
        var seconds: Double
    }

    static func run(_ args: Args) async throws -> Int32 {
        let url = URL(filePath: args.string("out") ?? RampFixture.defaultRelativePath)
        let data = RampFixture.wavData()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let report = Report(path: url.path, bytes: data.count, sha256: digest, sampleRate: RampFixture.sampleRate,
                            seconds: RampFixture.seconds)
        if args.flag("json") { printJSON(report) } else { print("wrote \(report.path) (\(report.bytes) bytes, sha256 \(digest))") }
        return 0
    }
}
