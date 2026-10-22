import Foundation
import CoreGraphics

// ===== wamp (verbatim from Wamp/Skinning/IniParser.swift + RegionParser.swift, MIT (c) 2026 Valerii Bakalenko) =====
enum IniParser {
    static func parse(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section: String?
        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let sectionRegex = try! NSRegularExpression(pattern: #"^\s*\[(.+?)\]\s*$"#)
        let propertyRegex = try! NSRegularExpression(pattern: #"^\s*([^;][^=]*?)\s*=\s*(.*?)\s*$"#)
        for line in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(";") { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if let m = sectionRegex.firstMatch(in: trimmed, range: range),
               let r = Range(m.range(at: 1), in: trimmed) {
                section = String(trimmed[r]).lowercased()
                if result[section!] == nil { result[section!] = [:] }
            } else if let s = section,
                      let m = propertyRegex.firstMatch(in: trimmed, range: range),
                      let kr = Range(m.range(at: 1), in: trimmed),
                      let vr = Range(m.range(at: 2), in: trimmed) {
                let key = String(trimmed[kr]).lowercased()
                var value = String(trimmed[vr])
                if value.count >= 2,
                   (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
                result[s]?[key] = value
            }
        }
        return result
    }
}
enum WampRegionParser {
    static func parseMainWindowRegion(_ text: String, windowHeight: CGFloat = 116) -> [[CGPoint]]? {
        let ini = IniParser.parse(text)
        guard let section = ini["normal"],
              let numpointsStr = section["numpoints"],
              let pointlistStr = section["pointlist"] else { return nil }
        let counts = numpointsStr.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !counts.isEmpty else { return nil }
        let coords = pointlistStr
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { (token: Substring) -> CGPoint? in
                let parts = token.split(separator: ",")
                guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
                return CGPoint(x: x, y: windowHeight - y)
            }
        var polygons: [[CGPoint]] = []
        var cursor = 0
        for count in counts {
            guard count >= 3, count <= coords.count - cursor else { break }
            polygons.append(Array(coords[cursor..<(cursor + count)]))
            cursor += count
        }
        return polygons.isEmpty ? nil : polygons
    }
}
// ===== macamp (verbatim from Sources/MacAmpCore/Skin.swift, MIT (c) 2026 André Hickmann Kuschnereit) =====
func macampParseRegions(_ text: String) -> [String: [[CGPoint]]] {
    var counts: [String: [Int]] = [:]
    var points: [String: [Int]] = [:]
    var section = ""
    var key = ""
    func numbers(_ value: Substring) -> [Int] {
        value.split { !$0.isNumber && $0 != "-" }.compactMap { Int($0) }
    }
    for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            section = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
            key = ""
            continue
        }
        let pair = line.split(separator: "=", maxSplits: 1)
        if pair.count == 2 {
            key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "numpoints" { counts[section] = numbers(pair[1]) }
            if key == "pointlist" { points[section] = numbers(pair[1]) }
        } else if key == "pointlist" {
            points[section, default: []] += numbers(line)
        }
    }
    return counts.reduce(into: [:]) { regions, item in
        var values = (points[item.key] ?? [])[...]
        regions[item.key] = item.value.compactMap { count in
            guard values.count >= count * 2 else { return nil }
            return (0..<count).map { _ in CGPoint(x: values.removeFirst(), y: values.removeFirst()) }
        }
    }
}
func macampParseVisColors(_ text: String) -> [[Int]] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
        let values = line.split(separator: "/").first?
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? []
        guard values.count >= 3 else { return nil }
        return Array(values.prefix(3))
    }
}
// ===== Bitamp (verbatim logic from Sources/BitampKit/Skin/WszSkin.swift parseVisColors, MIT (c) 2026 Ryan Romanosky) =====
func bitampParseVisColors(_ text: String) -> [[Int]]? {
    let colors = text.split(whereSeparator: \.isNewline).compactMap { line -> [Int]? in
        let numbers = line.split(whereSeparator: { !$0.isNumber }).prefix(3).compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return numbers.map { min($0, 255) }
    }
    return colors.count >= 24 ? Array(colors.prefix(24)) : nil
}
// ===== wamp ViscolorsParser (verbatim regex/logic; NSColor replaced by [Int]) =====
func wampParseVis(_ text: String) -> [[Int]] {
    let colorRegex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s*,?\s*(\d+)\s*,?\s*(\d+)"#)
    var colors = Array(repeating: [-1,-1,-1], count: 24)
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var colorIndex = 0
    for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
        guard colorIndex < 24 else { break }
        let s = String(line); let range = NSRange(s.startIndex..., in: s)
        guard let m = colorRegex.firstMatch(in: s, range: range),
              let rR = Range(m.range(at: 1), in: s), let gR = Range(m.range(at: 2), in: s), let bR = Range(m.range(at: 3), in: s),
              let r = Int(s[rR]), let g = Int(s[gR]), let b = Int(s[bR]) else { continue }
        colors[colorIndex] = [r,g,b]; colorIndex += 1
    }
    return colors
}

func fmt(_ polys: [[CGPoint]]?) -> [String] {
    (polys ?? []).map { $0.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ") }
}
var out: [String: Any] = [:]
for path in CommandLine.arguments.dropFirst() {
    let data = FileManager.default.contents(atPath: path)!
    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)!
    let name = (path as NSString).lastPathComponent
    if name.lowercased().hasPrefix("region") {
        let w = WampRegionParser.parseMainWindowRegion(text)?.map { $0.map { CGPoint(x: $0.x, y: 116 - $0.y) } }
        let m = macampParseRegions(text)
        out[name] = ["wamp_normal": fmt(w), "macamp": m.mapValues { fmt($0) }]
    } else {
        out[name] = ["wamp": wampParseVis(text), "macamp": macampParseVisColors(text), "bitamp": bitampParseVisColors(text) as Any]
    }
}
let json = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
FileManager.default.createFile(atPath: "/tmp/sudamp-priorart/experiments/parsers/swift_out.json", contents: json)
print("ok", out.count)
