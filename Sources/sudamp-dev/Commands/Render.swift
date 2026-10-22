// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SkinKit

/// `sudamp-dev render --skin <wsz|sudamp-dark> --window main|shade|eq|eq-shade|playlist --state <json> --out <png>`
///
/// Renders one window with SkinKit's pure composer and writes `<out>` (PNG), `<base>.rgba` (raw RGBA8),
/// `<base>.sha256` (hash of the RGBA8 bytes, which goldens compare; PNG bytes vary across macOS versions) and
/// `<base>.json` (render metadata, also printed). Exit 3 if the skin is rejected. `--bench N` also times N renders
/// and the skin load, printing a second JSON line with averages in milliseconds.
enum RenderCommand {
    static func run(_ args: Args) async throws -> Int32 {
        guard let out = args.string("out") else {
            stderr("usage: sudamp-dev render [--skin <wsz>] [--window main|shade|eq|eq-shade|playlist] [--state <json>] --out <png>")
            return 64
        }
        let skin: Skin
        switch SkinSource.load(args.string("skin")) {
        case .success(let loaded): skin = loaded
        case .failure(let rejection):
            printJSON(["ok": "false", "rejected": rejection.kind, "message": rejection.description])
            return 3
        }

        var state = WindowState()
        if let path = args.string("state") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            state = try JSONDecoder().decode(WindowState.self, from: data)
        }
        let windowName = args.string("window") ?? state.window?.rawValue ?? "main"
        guard let window = WindowKind(rawValue: windowName) else {
            stderr("unknown window \(windowName); use main, shade, eq, eq-shade or playlist")
            return 64
        }

        if let iterations = args.int("bench"), iterations > 0 {
            let loadStart = Date()
            if let path = args.string("skin"), path != "sudamp-dark" {
                _ = SkinLoader.load(url: URL(fileURLWithPath: path))
            }
            let loadMs = Date().timeIntervalSince(loadStart) * 1000
            let start = Date()
            for _ in 0..<iterations { _ = WindowComposer.render(window, state: state, skin: skin) }
            let renderMs = Date().timeIntervalSince(start) * 1000 / Double(iterations)
            printJSON(["window": window.rawValue, "iterations": String(iterations),
                       "renderMs": String(format: "%.3f", renderMs), "skinLoadMs": String(format: "%.2f", loadMs)])
        }
        let result = WindowComposer.render(window, state: state, skin: skin)
        let outURL = URL(fileURLWithPath: out)
        let base = outURL.pathExtension.lowercased() == "png" ? outURL.deletingPathExtension() : outURL
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let png = result.bitmap.pngData() else {
            stderr("PNG encoding failed")
            return 1
        }
        try png.write(to: outURL)
        try result.bitmap.rgbaData.write(to: base.appendingPathExtension("rgba"))
        try Data((result.metadata.sha256 + "\n").utf8).write(to: base.appendingPathExtension("sha256"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result.metadata).write(to: base.appendingPathExtension("json"))
        printJSON(result.metadata, pretty: args.flag("pretty"))
        return 0
    }
}

/// Resolves `--skin`: absent or "sudamp-dark" is the built-in skin; anything else is a .wsz path.
enum SkinSource {
    static func load(_ argument: String?, fallback: Bool = true) -> Result<Skin, ZipError> {
        guard let argument, argument != "sudamp-dark" else { return .success(SudampDark.skin) }
        let result = SkinLoader.load(url: URL(fileURLWithPath: argument), fallback: fallback ? SudampDark.skin : nil)
        if let skin = result.skin { return .success(skin) }
        return .failure(result.rejection ?? .notAZip)
    }
}
