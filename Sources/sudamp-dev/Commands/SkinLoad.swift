// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SkinKit

/// `sudamp-dev skin-load <file.wsz> [--no-fallback] [--pretty]`
///
/// Loads a skin through SkinKit's capped reader and prints a JSON report: where each sheet came from (skin,
/// fallback or missing), text files, region sections, problems and the caps in force. Exit 0 if the skin
/// loaded, 3 if it was rejected (not a zip, caps exceeded). For the zip-bomb gate run it under
/// `/usr/bin/time -l` and read "maximum resident set size".
enum SkinLoadCommand {
    struct Output: Encodable {
        var ok: Bool
        var path: String
        var rejected: Rejection?
        var report: SkinLoadReport?
        var peakRSSBytes: Int
    }

    struct Rejection: Encodable {
        var kind: String
        var message: String
    }

    static func run(_ args: Args) async throws -> Int32 {
        guard let path = args.positionals.first ?? args.string("skin") else {
            stderr("usage: sudamp-dev skin-load <file.wsz> [--no-fallback] [--pretty]")
            return 64
        }
        let noFallback = args.flag("no-fallback")
        let result = SkinLoader.load(url: URL(fileURLWithPath: path), fallback: noFallback ? nil : SudampDark.skin)
        let output = Output(
            ok: result.skin != nil, path: path,
            rejected: result.rejection.map { Rejection(kind: $0.kind, message: $0.description) },
            report: result.skin?.report, peakRSSBytes: peakResidentBytes())
        printJSON(output, pretty: args.flag("pretty"))
        return result.skin != nil ? 0 : 3
    }
}

/// Peak resident set size of this process so far (ru_maxrss is in bytes on macOS).
func peakResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}
