// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A JSON value that keeps object key order and number spelling, so `catalog-tool build` can write `feed.json`
/// deterministically in the curator's layout (`JSONValue` and `JSONSerialization` lose both).
///
/// The parser is strict RFC 8259 (no comments, no trailing commas, no duplicate keys, UTF-8 only), with a depth cap.
public indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    /// The literal as written (`1.0` stays `1.0`).
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: OrderedJSON

        public init(_ key: String, _ value: OrderedJSON) {
            self.key = key
            self.value = value
        }
    }

    public struct ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        public let offset: Int
        public let message: String
        public var description: String { "JSON error at byte \(offset): \(message)" }
    }

    public static let maxDepth = 64

    // MARK: Access

    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var members: [Member]? { if case .object(let m) = self { return m }; return nil }
    public var elements: [OrderedJSON]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var keys: [String] { members?.map(\.key) ?? [] }

    /// An integral number literal (`10`, not `10.0`).
    public var intLiteral: Int? {
        guard case .number(let s) = self, s.wholeMatch(of: #/-?(0|[1-9][0-9]{0,15})/#) != nil else { return nil }
        return Int(s)
    }

    /// A copy with `key` set (replaced in place, or appended).
    public func setting(_ key: String, to value: OrderedJSON) -> OrderedJSON {
        guard var m = members else { return self }
        if let i = m.firstIndex(where: { $0.key == key }) { m[i].value = value } else { m.append(Member(key, value)) }
        return .object(m)
    }

    /// A copy without `key`.
    public func removing(_ key: String) -> OrderedJSON {
        guard let m = members else { return self }
        return .object(m.filter { $0.key != key })
    }

    /// The same value as `JSONValue` (for the feed decoder and validators).
    public var jsonValue: JSONValue {
        switch self {
        case .null: .null
        case .bool(let b): .bool(b)
        case .number(let s): .number(Double(s) ?? .nan)
        case .string(let s): .string(s)
        case .array(let a): .array(a.map(\.jsonValue))
        case .object(let m): .object(Dictionary(m.map { ($0.key, $0.value.jsonValue) }, uniquingKeysWith: { a, _ in a }))
        }
    }

    // MARK: Writing

    /// One line, `{"a": 1, "b": [1, 2]}` (the feed's per-item layout).
    public var compact: String {
        var out = ""
        writeCompact(into: &out)
        return out
    }

    /// Two-space indentation, one member per line, `[]`/`{}` when empty; `level` indents nested lines.
    public func pretty(level: Int = 0) -> String {
        var out = ""
        writePretty(into: &out, level: level)
        return out
    }

    private func writeCompact(into out: inout String) {
        switch self {
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += ", " }
                v.writeCompact(into: &out)
            }
            out += "]"
        case .object(let m):
            out += "{"
            for (i, member) in m.enumerated() {
                if i > 0 { out += ", " }
                out += Self.quote(member.key) + ": "
                member.value.writeCompact(into: &out)
            }
            out += "}"
        default:
            writeScalar(into: &out)
        }
    }

    private func writePretty(into out: inout String, level: Int) {
        let pad = String(repeating: "  ", count: level + 1), close = String(repeating: "  ", count: level)
        switch self {
        case .array(let a) where a.isEmpty: out += "[]"
        case .object(let m) where m.isEmpty: out += "{}"
        case .array(let a):
            out += "[\n"
            for (i, v) in a.enumerated() {
                out += pad
                v.writePretty(into: &out, level: level + 1)
                out += i < a.count - 1 ? ",\n" : "\n"
            }
            out += close + "]"
        case .object(let m):
            out += "{\n"
            for (i, member) in m.enumerated() {
                out += pad + Self.quote(member.key) + ": "
                member.value.writePretty(into: &out, level: level + 1)
                out += i < m.count - 1 ? ",\n" : "\n"
            }
            out += close + "}"
        default:
            writeScalar(into: &out)
        }
    }

    private func writeScalar(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let s): out += s
        case .string(let s): out += Self.quote(s)
        case .array, .object: break
        }
    }

    /// JSON string literal: `"` `\` and control characters escaped, everything else (including non-ASCII) as is.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws(ParseError) -> OrderedJSON {
        var p = Parser(bytes: [UInt8](data))
        p.skipWhitespace()
        let v = try p.value(depth: 0)
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw p.error("trailing characters") }
        return v
    }

    public static func parse(_ text: String) throws(ParseError) -> OrderedJSON { try parse(Data(text.utf8)) }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        func error(_ m: String) -> ParseError { ParseError(offset: i, message: m) }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func value(depth: Int) throws(ParseError) -> OrderedJSON {
            guard depth < OrderedJSON.maxDepth else { throw error("nested too deeply") }
            guard i < bytes.count else { throw error("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws(ParseError) {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw error("invalid literal") }
            i += w.count
        }

        mutating func object(depth: Int) throws(ParseError) -> OrderedJSON {
            i += 1
            var members: [Member] = []
            var seen = Set<String>()
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                guard seen.insert(key).inserted else { throw error("duplicate key \"\(key)\"") }
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
                i += 1
                skipWhitespace()
                members.append(Member(key, try value(depth: depth + 1)))
                skipWhitespace()
                guard i < bytes.count else { throw error("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                guard bytes[i] == UInt8(ascii: "}") else { throw error("expected ',' or '}'") }
                i += 1
                return .object(members)
            }
        }

        mutating func array(depth: Int) throws(ParseError) -> OrderedJSON {
            i += 1
            var out: [OrderedJSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array([]) }
            while true {
                skipWhitespace()
                out.append(try value(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw error("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                guard bytes[i] == UInt8(ascii: "]") else { throw error("expected ',' or ']'") }
                i += 1
                return .array(out)
            }
        }

        mutating func number() throws(ParseError) -> String {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            guard s.wholeMatch(of: #/-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/#) != nil else {
                i = start
                throw error("invalid value")
            }
            return s
        }

        mutating func string() throws(ParseError) -> String {
            i += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() throws(ParseError) {
                guard !raw.isEmpty else { return }
                guard let s = String(validating: raw, as: UTF8.self) else { throw error("invalid UTF-8") }
                scalars.append(contentsOf: s.unicodeScalars)
                raw.removeAll()
            }
            while i < bytes.count {
                let b = bytes[i]
                switch b {
                case UInt8(ascii: "\""):
                    i += 1
                    try flush()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    try flush()
                    i += 1
                    guard i < bytes.count else { throw error("unexpected end") }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code) {
                            guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                                throw error("unpaired surrogate")
                            }
                            i += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw error("unpaired surrogate") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let u = Unicode.Scalar(code) else { throw error("invalid \\u escape") }
                        scalars.append(u)
                    default: throw error("invalid escape")
                    }
                default:
                    guard b >= 0x20 else { throw error("control character in string") }
                    raw.append(b)
                    i += 1
                }
            }
            throw error("unterminated string")
        }

        mutating func hex4() throws(ParseError) -> UInt32 {
            guard i + 4 <= bytes.count, bytes[i..<i + 4].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
                  let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw error("invalid \\u escape")
            }
            i += 4
            return v
        }
    }
}
