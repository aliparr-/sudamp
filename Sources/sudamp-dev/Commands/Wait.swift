// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation

/// `sudamp-dev wait --profile <P> --state <s>[,<s>…] [--timeout <s>] [--genre <id>] [--stream-not <id>]
///  [--resumed=true|false] [--now-playing <state>] [--json]` (PLAN M2).
///
/// Polls `<P>/debug/state.json` (written by the running app, debounced 250 ms) until every given condition holds:
/// exit 0 and print the matching sample; exit 1 on timeout, printing the last sample read to stderr.
enum WaitCommand {
    static let usage = """
    usage: sudamp-dev wait --profile <P> [--state <s>[,<s>…]] [--timeout <s>] [--genre <id>] [--stream-not <id>]
                           [--resumed=true|false] [--now-playing <playbackState>] [--json]
    """

    static func run(_ args: Args) async throws -> Int32 {
        var query = DebugStateQuery()
        if let s = args.string("state") {
            query.states = Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            if let bad = query.states.first(where: { !AutomationScript.knownStates.contains($0) && $0 != "shutdown" }) {
                stderr("unknown state \(bad)\n\(usage)")
                return 64
            }
        }
        query.genre = args.string("genre")
        query.streamNot = args.string("stream-not")
        if let r = args.string("resumed") {
            guard let b = Bool(r) else {
                stderr(usage)
                return 64
            }
            query.resumed = b
        }
        query.nowPlayingState = args.string("now-playing")
        guard query != DebugStateQuery() else {
            stderr("nothing to wait for\n\(usage)")
            return 64
        }
        let timeout = args.double("timeout") ?? 10
        let file = Paths.resolve().debugState
        let started = Date()
        let (matched, last) = await query.wait(file: file, timeout: timeout)
        let ms = Int((Date().timeIntervalSince(started) * 1000).rounded())
        if let matched {
            if args.flag("json") {
                print(#"{"matched":true,"ms":\#(ms),"state":"\#(matched.state ?? "")","genre":"\#(matched.genre ?? "")","stream":"\#(matched.streamID ?? "")"}"#)
            } else {
                print("matched after \(ms) ms: \(matched.summary)")
            }
            return 0
        }
        stderr("sudamp-dev wait: timed out after \(ms) ms; last \(file.path): \(last?.summary ?? "unreadable or missing")")
        return 1
    }
}
