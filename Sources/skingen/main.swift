// SPDX-License-Identifier: GPL-3.0-or-later
// skingen: writes the original "sudamp Dark" skin as a classic .wsz (DESIGN §8.3, PLAN M4).
//
//   skingen [--out <file.wsz>]          write the skin (default Fixtures/skins/sudamp-dark.wsz)
//   skingen --check <file.wsz>          generate twice, require identical bytes equal to <file.wsz>
//   skingen --sheets <dir>              also write each sheet as PNG for review
//
// Output is byte-stable: fixed ZIP timestamps, sorted names, SkinKit's own DEFLATE and BMP encoders.
import CryptoKit
import Foundation
import SkinKit

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("skingen: \(message)\n".utf8))
    exit(code)
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name) else { return nil }
    guard i + 1 < arguments.count else { fail("\(name) needs a value", code: 64) }
    let value = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
    return value
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("usage: skingen [--out <file.wsz>] [--check <file.wsz>] [--sheets <dir>]")
    exit(0)
}

let check = option("--check")
let out = option("--out")
let sheetsDir = option("--sheets")
guard arguments.isEmpty else { fail("unknown arguments: \(arguments.joined(separator: " "))", code: 64) }

let first = SudampDark.archive()
if let check {
    let second = SudampDark.archive()
    guard first == second else { fail("two runs produced different bytes (\(sha256(first)) vs \(sha256(second)))") }
    guard let committed = FileManager.default.contents(atPath: check) else { fail("cannot read \(check)") }
    guard committed == first else {
        fail("\(check) is stale: committed \(sha256(committed)), generated \(sha256(first)); run skingen --out \(check)")
    }
    print("ok \(sha256(first)) \(first.count) bytes, two runs identical, matches \(check)")
    exit(0)
}

let target = out ?? "Fixtures/skins/\(SudampDark.fileName)"
do {
    try first.write(to: URL(fileURLWithPath: target), options: .atomic)
} catch {
    fail("cannot write \(target): \(error)")
}
print("wrote \(target): \(first.count) bytes, sha256 \(sha256(first))")

if let sheetsDir {
    let dir = URL(fileURLWithPath: sheetsDir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let result = SkinLoader.load(data: first, name: "sudamp Dark", fallback: nil)
    guard let skin = result.skin else { fail("generated skin does not load: \(String(describing: result.rejection))") }
    for (name, sheet) in skin.sheets.sorted(by: { $0.key < $1.key }) {
        guard let png = sheet.pngData() else { continue }
        try? png.write(to: dir.appending(path: "\(name).png"))
    }
    print("wrote \(skin.sheets.count) sheet PNGs to \(sheetsDir)")
}
