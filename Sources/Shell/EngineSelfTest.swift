// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import Resolver
import Synchronization

/// `sudamp --selftest --engine-check [--profile P] [--json]` (PLAN M0 L1): proves the app — including a
/// hardened-runtime build — can spawn the downloaded yt-dlp engine in its scrubbed environment.
enum EngineSelfTest {
    nonisolated struct Report: Encodable, Sendable {
        var engineVersion: String?
        var executable: String?
        var output: String?
        var coldMs: Double?
        var warmMedianMs: Double?
        var error: String?
        var ok: Bool
    }

    static func run(arguments: [String]) -> Report {
        let paths = Paths.resolve(arguments: arguments)
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.set(await check(paths: paths))
            done.signal()
        }
        done.wait()
        return box.value ?? Report(error: "no result", ok: false)
    }

    nonisolated private static func check(paths: Paths) async -> Report {
        let layout = EngineLayout(paths: paths)
        let store = EngineStore(layout: layout)
        guard let current = await store.current() else {
            return Report(error: "no engine installed in \(paths.appSupport.path)", ok: false)
        }
        let exe = current.executableURL(in: layout)
        do {
            let smoke = try await store.smokeTest(executable: exe, expectedVersion: current.version)
            return Report(engineVersion: current.version, executable: exe.path, output: smoke.output,
                          coldMs: smoke.coldMs, warmMedianMs: smoke.warmMedianMs,
                          ok: smoke.output.contains(current.version))
        } catch {
            return Report(engineVersion: current.version, executable: exe.path, error: "\(error)", ok: false)
        }
    }

    /// Hands the detached task's result back to the waiting thread.
    nonisolated private final class ResultBox: Sendable {
        private let storage = Mutex<Report?>(nil)
        var value: Report? { storage.withLock { $0 } }
        func set(_ report: Report) { storage.withLock { $0 = report } }
    }

    static func json(_ report: Report, pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
