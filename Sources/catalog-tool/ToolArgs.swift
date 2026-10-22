// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `catalog-tool <command> [positionals] [--flag] [--key value | --key=value]`.
struct ToolArgs {
    let command: String?
    let positionals: [String]
    private let options: [String: String]
    private let flags: Set<String>

    /// Options that take a value; everything else starting with `--` is a flag.
    static let valued: Set<String> = [
        "key", "pub", "sig", "out", "profile", "url", "budget", "source", "limit", "genre", "interval", "youtube-interval",
        "min-pass", "bundled", "expires-days", "rule", "sources", "qjs", "seed", "feed", "catalog",
    ]

    init(_ argv: some Sequence<String>) {
        var it = Array(argv).makeIterator()
        var command: String?
        var positionals: [String] = []
        var options: [String: String] = [:]
        var flags = Set<String>()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if Self.valued.contains(body), let v = it.next() {
                    options[body] = v
                } else {
                    flags.insert(body)
                }
            } else if command == nil {
                command = a
            } else {
                positionals.append(a)
            }
        }
        self.command = command
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    func string(_ k: String) -> String? { options[k] }
    func int(_ k: String) -> Int? { options[k].flatMap { Int($0) } }
    func double(_ k: String) -> Double? { options[k].flatMap { Double($0) } }
    func flag(_ k: String) -> Bool { flags.contains(k) }
    func list(_ k: String) -> [String]? {
        options[k].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    }
}

func stderr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func printJSON(_ value: some Encodable) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? e.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

/// `catalog/` from an explicit path, else found by walking up from the working directory.
func catalogDirectory(_ explicit: String?) -> URL? {
    let fm = FileManager.default
    if let explicit { return URL(filePath: (explicit as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
    var dir = URL(filePath: fm.currentDirectoryPath, directoryHint: .isDirectory).standardizedFileURL
    for _ in 0..<8 {
        let c = dir.appending(path: "catalog", directoryHint: .isDirectory)
        if fm.fileExists(atPath: c.appending(path: "release.json").path) { return c }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}

func isDirectory(_ url: URL) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
}

func milliseconds(_ d: Duration) -> Double {
    let c = d.components
    return (Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15).rounded()
}

/// User-Agent for the tool's own requests (radio-browser asks clients to identify themselves).
let toolUserAgent = "sudamp-catalog-tool/0.1"
