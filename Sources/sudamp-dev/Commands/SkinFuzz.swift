// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import SkinKit

/// `sudamp-dev skin-fuzz <dir> [--mutations N] [--seed S] [--no-render] [--pretty]`
/// `sudamp-dev skin-fuzz --make-bomb <path> [--size <bytes>]`
///
/// Mutates every .wsz under <dir> (plus the built-in sudamp Dark) with SkinKit's fuzzer (truncation, bit flips,
/// wrong sizes, nested folders, CP437 names, duplicates, corrupt images, end-record damage), loads each result
/// and renders all windows. Any crash kills the process, so a JSON report on stdout means 0 crashes. The run is
/// reproducible from --seed. --make-bomb writes a zip bomb (default: 1 GiB MAIN.BMP in ~1 MB) for the RSS gate.
enum SkinFuzzCommand {
    struct Report: Encodable {
        var seed: UInt64
        var mutations: Int
        var baseSkins: [String]
        var loaded: Int
        var rejected: Int
        var rendered: Int
        var crashes: Int
        var byMutation: [String: Int]
        var rejectionKinds: [String: Int]
        var problemKinds: [String: Int]
        var seconds: Double
        var peakRSSBytes: Int
    }

    static func run(_ args: Args) async throws -> Int32 {
        if let bombPath = args.string("make-bomb") {
            let size = args.int("size") ?? (1 << 30)
            let bomb = ZipBomb.make(uncompressedSize: size)
            try bomb.write(to: URL(fileURLWithPath: bombPath))
            printJSON(["path": bombPath, "bytes": String(bomb.count), "declaredEntryBytes": String(size)])
            return 0
        }
        guard let dir = args.positionals.first else {
            stderr("usage: sudamp-dev skin-fuzz <dir> [--mutations N] [--seed S] [--no-render]")
            return 64
        }
        let count = args.int("mutations") ?? 200
        let seed = UInt64(args.string("seed") ?? "") ?? 0x5D_A3B1
        let render = !args.flag("no-render")

        var bases: [(name: String, data: Data)] = [("sudamp-dark (generated)", SudampDark.archive())]
        let root = URL(fileURLWithPath: dir)
        let paths = (FileManager.default.subpaths(atPath: root.path) ?? []).filter { $0.lowercased().hasSuffix(".wsz") }
        for path in paths.sorted() {
            if let data = try? Data(contentsOf: root.appending(path: path)) { bases.append((path, data)) }
        }

        var rng = SeededRandom(seed: seed)
        var report = Report(seed: seed, mutations: count, baseSkins: bases.map(\.name), loaded: 0, rejected: 0,
                            rendered: 0, crashes: 0, byMutation: [:], rejectionKinds: [:], problemKinds: [:],
                            seconds: 0, peakRSSBytes: 0)
        let started = Date()
        for i in 0..<count {
            let base = bases[i % bases.count]
            let mutation = SkinFuzzer.Mutation.allCases[Int.random(in: 0..<SkinFuzzer.Mutation.allCases.count, using: &rng)]
            report.byMutation[mutation.rawValue, default: 0] += 1
            var data = SkinFuzzer.mutate(base.data, mutation, using: &rng)
            // Half the time stack a second mutation, so damage combines.
            if Bool.random(using: &rng) {
                data = SkinFuzzer.mutate(data, SkinFuzzer.Mutation.allCases.randomElement(using: &rng)!, using: &rng)
            }
            let result = SkinLoader.load(data: data, name: "fuzz-\(i)")
            if let skin = result.skin {
                report.loaded += 1
                for problem in skin.report.problems { report.problemKinds[problem.kind, default: 0] += 1 }
                if render {
                    var state = WindowState()
                    state.playback = .playing
                    state.elapsed = 83
                    state.duration = 300
                    state.title = "FUZZ \(i) ÅÄÖ 東京"
                    state.visualizer = VisualizerFrame(mode: .spectrum, bars: (0..<19).map { _ in Int.random(in: 0...16, using: &rng) })
                    state.playlist.rows = [.init(title: "One", duration: "1:00", tag: "SC")]
                    for window in WindowKind.allCases {
                        _ = WindowComposer.render(window, state: state, skin: skin)
                        report.rendered += 1
                    }
                }
            } else {
                report.rejected += 1
                report.rejectionKinds[result.rejection?.kind ?? "unknown", default: 0] += 1
            }
        }
        report.seconds = (Date().timeIntervalSince(started) * 100).rounded() / 100
        report.peakRSSBytes = peakResidentBytes()
        printJSON(report, pretty: args.flag("pretty"))
        return 0
    }
}
