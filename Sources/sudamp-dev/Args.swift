// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Tiny argument parser for sudamp-dev subcommands.
///
/// - `--key=value` always sets a value.
/// - `--flag` for names in `booleanFlags` never consumes the next token (so `--json <url>` works).
/// - `--key value` / `-k value` take the next token as the value unless it starts with `-` (negative numbers
///   such as `-3` are still accepted as values).
/// - Everything else is a positional.
struct Args {
    /// Every boolean flag any subcommand reads with `flag(_:)`. Add new ones here.
    static let booleanFlags: Set<String> = [
        "json", "pretty", "help", "ladder", "no-fallback", "no-render", "restore", "skip-verify", "check",
        "no-engine", "plain", "live", "verbose", "keep", "install-engine", "prefetch",
    ]

    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ argv: [String], booleanFlags: Set<String> = Args.booleanFlags) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if let key = Args.optionName(a) {
                if let eq = key.firstIndex(of: "=") {
                    options[String(key[..<eq])] = String(key[key.index(after: eq)...])
                } else if booleanFlags.contains(key) {
                    flags.insert(key)
                } else if i + 1 < argv.count, Args.optionName(argv[i + 1]) == nil {
                    options[key] = argv[i + 1]
                    i += 1
                } else {
                    flags.insert(key)
                }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    /// `--name` / `-n` → name; nil for positionals, `-` and negative numbers.
    private static func optionName(_ token: String) -> String? {
        if token.hasPrefix("--"), token.count > 2 { return String(token.dropFirst(2)) }
        if token.hasPrefix("-"), token.count > 1, Double(token) == nil { return String(token.dropFirst()) }
        return nil
    }

    func flag(_ name: String) -> Bool { flags.contains(name) || options[name] == "true" }
    func string(_ name: String) -> String? { options[name] }
    func double(_ name: String) -> Double? { options[name].flatMap(Double.init) }
    func int(_ name: String) -> Int? { options[name].flatMap { Int($0) } }
}

/// Writes a JSON-encodable value to stdout (sorted keys, one line unless `pretty`).
func printJSON<T: Encodable>(_ value: T, pretty: Bool = false) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
}

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
