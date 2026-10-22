// SPDX-License-Identifier: GPL-3.0-or-later

/// A stream's stable identity, derived from its source and canonical ref (DESIGN §7.1):
/// `yt:<videoId>`, `ytl:@handle` or `ytl:UC…`, `sc:user/slug`, `mc:user/slug`, `radio:<slug>`.
/// Bags, health, bans, favourites and history are keyed by it, so it must never depend on a URL's spelling.
public struct StreamID: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// Accepts only well-formed IDs (prefix plus a ref that passes the canonicaliser).
    public init?(rawValue: String) {
        guard StreamID.parse(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(unchecked: String) { rawValue = unchecked }

    /// The ID for a canonical ref. Radio IDs are curator-chosen slugs, so radio takes the slug, not the URL.
    public static func make(source: SourceKind, ref: String) -> StreamID? {
        switch source {
        case .radio:
            return Canonicaliser.isValidRadioSlug(ref) ? StreamID(unchecked: "radio:" + ref) : nil
        default:
            guard let canonical = try? Canonicaliser.canonicalRef(ref, for: source) else { return nil }
            return StreamID(unchecked: prefix(for: source) + canonical)
        }
    }

    /// Source and ref (radio: the slug) encoded in the ID.
    public var source: SourceKind { StreamID.parse(rawValue)!.source }
    public var ref: String { StreamID.parse(rawValue)!.ref }

    public var description: String { rawValue }
    public static func < (a: StreamID, b: StreamID) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = StreamID(rawValue: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid stream id \(s)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    static func prefix(for source: SourceKind) -> String {
        switch source {
        case .youtube: "yt:"
        case .youtubeLive: "ytl:"
        case .soundcloud: "sc:"
        case .mixcloud: "mc:"
        case .radio: "radio:"
        }
    }

    private static func parse(_ raw: String) -> (source: SourceKind, ref: String)? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let head = raw[...colon], ref = String(raw[raw.index(after: colon)...])
        let source: SourceKind
        switch head {
        case "yt:": source = .youtube
        case "ytl:": source = .youtubeLive
        case "sc:": source = .soundcloud
        case "mc:": source = .mixcloud
        case "radio:": source = .radio
        default: return nil
        }
        if source == .radio { return Canonicaliser.isValidRadioSlug(ref) ? (source, ref) : nil }
        // IDs hold the canonical form only, so `sc:User/Slug` is not an ID even though a pasted URL could be.
        guard (try? Canonicaliser.canonicalRef(ref, for: source)) == ref else { return nil }
        return (source, ref)
    }
}

/// A genre's ID: lower-case words joined by single hyphens, at most 32 characters (`deep-house`).
public struct GenreID: RawRepresentable, Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count <= 32, rawValue.wholeMatch(of: #/[a-z0-9]+(-[a-z0-9]+)*/#) != nil else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
    public static func < (a: GenreID, b: GenreID) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = GenreID(rawValue: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid genre id \(s)"))
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

extension SourceKind {
    /// The service behind a source: YouTube VOD and `/live` share one token bucket, breaker and kill switch.
    public var platform: SourceKind { self == .youtubeLive ? .youtube : self }
}

/// Dictionary keys: lets `[StreamID: T]` and `[GenreID: T]` encode as JSON objects (session.json stays readable).
struct IDCodingKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension StreamID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { IDCodingKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

extension GenreID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { IDCodingKey(stringValue: rawValue) }
    public init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}
