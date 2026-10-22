// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// `feed.json` (DESIGN §7.1): one versioned document carrying the catalog and the engine settings.
public struct FeedDocument: Sendable, Equatable {
    /// The only major schema this build understands. A document with another `schema` is rejected whole.
    public static let supportedSchema = 1

    public let schema: Int
    public let revision: Int
    public let generatedAt: Date
    /// Applies to fetched documents only (DESIGN §7.2); bundled documents never expire.
    public let expiresAt: Date?
    public let catalog: FeedCatalog
    public let engine: EngineConfig

    public init(schema: Int = FeedDocument.supportedSchema, revision: Int, generatedAt: Date, expiresAt: Date?,
                catalog: FeedCatalog, engine: EngineConfig) {
        self.schema = schema
        self.revision = revision
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.catalog = catalog
        self.engine = engine
    }
}

/// Why a whole document was refused.
public enum FeedError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidJSON
    case unsupportedSchema(Int)
    case missingField(String)
    case invalidField(String)

    public var description: String {
        switch self {
        case .invalidJSON: "not valid JSON"
        case .unsupportedSchema(let n): "unsupported schema \(n) (this build reads \(FeedDocument.supportedSchema))"
        case .missingField(let f): "missing field '\(f)'"
        case .invalidField(let f): "invalid field '\(f)'"
        }
    }
}

/// A catalog item the lenient decoder dropped, and why.
public struct DroppedItem: Sendable, Equatable, CustomStringConvertible {
    public enum Section: String, Sendable { case genre, stream }
    public let section: Section
    public let index: Int
    /// The item's `id`, when it had a readable one.
    public let id: String?
    public let reason: String

    public var description: String { "\(section.rawValue)[\(index)]\(id.map { " '\($0)'" } ?? ""): \(reason)" }
}

/// A decoded document plus everything the lenient decoder had to skip.
public struct FeedDecodeResult: Sendable {
    public let document: FeedDocument
    public let dropped: [DroppedItem]
    public let engineIssues: [EngineIssue]

    /// Nothing was dropped or rejected.
    public var isClean: Bool { dropped.isEmpty && engineIssues.isEmpty }
}

/// Decodes `feed.json`. Envelope fields are strict; catalog items are decoded one by one and dropped with a reason
/// when invalid; engine values are validated field by field over the previous configuration.
public enum FeedDecoder {
    public static let maxTitleLength = 200

    public static func decode(_ data: Data, previousEngine: EngineConfig = .defaults) throws(FeedError) -> FeedDecodeResult {
        guard let root = try? JSONValue.parse(data) else { throw .invalidJSON }
        return try decode(root, previousEngine: previousEngine)
    }

    public static func decode(_ root: JSONValue, previousEngine: EngineConfig = .defaults) throws(FeedError) -> FeedDecodeResult {
        guard root.objectValue != nil else { throw .invalidJSON }
        guard let schemaValue = root["schema"] else { throw .missingField("schema") }
        guard let schema = schemaValue.intValue else { throw .invalidField("schema") }
        guard schema == FeedDocument.supportedSchema else { throw .unsupportedSchema(schema) }
        guard let revisionValue = root["revision"] else { throw .missingField("revision") }
        guard let revision = revisionValue.intValue, revision >= 0 else { throw .invalidField("revision") }
        guard let generatedValue = root["generatedAt"] else { throw .missingField("generatedAt") }
        guard let generatedAt = generatedValue.stringValue.flatMap(parseDate) else { throw .invalidField("generatedAt") }
        var expiresAt: Date?
        if let e = root["expiresAt"], !e.isNull {
            guard let d = e.stringValue.flatMap(parseDate) else { throw .invalidField("expiresAt") }
            expiresAt = d
        }
        guard let catalogValue = root["catalog"] else { throw .missingField("catalog") }
        guard catalogValue.objectValue != nil else { throw .invalidField("catalog") }

        var dropped: [DroppedItem] = []
        let genres = decodeGenres(catalogValue["genres"], dropped: &dropped)
        let known = Set(genres.map(\.id))
        let streams = decodeStreams(catalogValue["streams"], knownGenres: known, dropped: &dropped)
        let (engine, issues) = EngineConfig.decode(root["engine"], previous: previousEngine)

        let document = FeedDocument(schema: schema, revision: revision, generatedAt: generatedAt, expiresAt: expiresAt,
                                    catalog: FeedCatalog(genres: genres, streams: streams), engine: engine)
        return FeedDecodeResult(document: document, dropped: dropped, engineIssues: issues)
    }

    // MARK: Items

    private static func decodeGenres(_ value: JSONValue?, dropped: inout [DroppedItem]) -> [Genre] {
        guard let items = value?.arrayValue else {
            if value != nil { dropped.append(DroppedItem(section: .genre, index: -1, id: nil, reason: "genres is not a list")) }
            return []
        }
        var seen = Set<GenreID>()
        var out: [Genre] = []
        for (i, item) in items.enumerated() {
            let rawID = item["id"]?.stringValue
            func drop(_ reason: String) { dropped.append(DroppedItem(section: .genre, index: i, id: rawID, reason: reason)) }
            guard let rawID, let id = GenreID(rawValue: rawID) else { drop("invalid or missing id"); continue }
            guard let name = item["name"]?.stringValue.flatMap(cleanText) else { drop("invalid or missing name"); continue }
            let order = item["order"]?.intValue ?? 0
            guard seen.insert(id).inserted else { drop("duplicate id"); continue }
            out.append(Genre(id: id, name: name, order: order))
        }
        return out
    }

    private static func decodeStreams(_ value: JSONValue?, knownGenres: Set<GenreID>,
                                      dropped: inout [DroppedItem]) -> [StreamRef] {
        guard let items = value?.arrayValue else {
            if value != nil { dropped.append(DroppedItem(section: .stream, index: -1, id: nil, reason: "streams is not a list")) }
            return []
        }
        var seen = Set<StreamID>()
        var out: [StreamRef] = []
        for (i, item) in items.enumerated() {
            switch decodeStream(item, knownGenres: knownGenres) {
            case .success(let s):
                if seen.insert(s.id).inserted { out.append(s) }
                else { dropped.append(DroppedItem(section: .stream, index: i, id: s.id.rawValue, reason: "duplicate id")) }
            case .failure(let reason):
                dropped.append(DroppedItem(section: .stream, index: i, id: item["id"]?.stringValue, reason: reason.text))
            }
        }
        return out
    }

    struct Reason: Error { let text: String }

    static func decodeStream(_ item: JSONValue, knownGenres: Set<GenreID>) -> Result<StreamRef, Reason> {
        func fail(_ s: String) -> Result<StreamRef, Reason> { .failure(Reason(text: s)) }
        guard item.objectValue != nil else { return fail("not an object") }
        guard let rawSource = item["source"]?.stringValue else { return fail("missing source") }
        guard let source = SourceKind(rawValue: rawSource) else { return fail("unknown source '\(rawSource)'") }
        guard let rawRef = item["ref"]?.stringValue else { return fail("missing ref") }
        let ref: String
        do { ref = try Canonicaliser.canonicalRef(rawRef, for: source) } catch { return fail(error.description) }

        // Non-radio IDs are derived from the ref, so one ref can never hide behind two IDs.
        let id: StreamID
        let rawID = item["id"]?.stringValue
        if source == .radio {
            guard let rawID, let parsed = StreamID(rawValue: rawID), parsed.source == .radio else {
                return fail("radio needs an id like radio:<slug>")
            }
            id = parsed
        } else {
            guard let derived = StreamID.make(source: source, ref: ref) else { return fail("invalid ref") }
            if let rawID, rawID != derived.rawValue { return fail("id does not match ref (expected \(derived))") }
            id = derived
        }

        guard let title = item["title"]?.stringValue.flatMap(cleanText) else { return fail("missing title") }
        guard let creator = item["creator"]?.stringValue.flatMap(cleanText) else { return fail("missing creator") }

        let kind: StreamKind
        switch source {
        case .radio: kind = .station
        case .youtubeLive: kind = .live
        default: kind = item["kind"]?.stringValue.flatMap(StreamKind.init(rawValue:)) ?? .default(for: source)
        }

        guard let rawGenres = item["genres"]?.arrayValue else { return fail("missing genres") }
        let genres = rawGenres.compactMap { $0.stringValue.flatMap(GenreID.init(rawValue:)) }.filter(knownGenres.contains)
        guard !genres.isEmpty else { return fail("no known genre") }

        var duration: Int?
        if let d = item["durationSec"], !d.isNull {
            guard let n = d.intValue, n >= 0 else { return fail("invalid durationSec") }
            duration = n
        }
        var weight = 1.0
        if let w = item["weight"], !w.isNull {
            guard let x = w.doubleValue, x.isFinite, x > 0, x <= 100 else { return fail("weight must be in (0, 100]") }
            weight = x
        }
        var homepage: URL?
        if let h = item["homepage"]?.stringValue {
            guard let url = validHomepage(h) else { return fail("invalid homepage") }
            homepage = url
        }
        if source == .radio && homepage == nil { return fail("radio needs a homepage") }

        var uniqueGenres: [GenreID] = []
        for g in genres where !uniqueGenres.contains(g) { uniqueGenres.append(g) }
        return .success(StreamRef(id: id, source: source, ref: ref, kind: kind, title: title, creator: creator,
                                  genres: uniqueGenres, durationSec: duration, weight: weight, homepage: homepage))
    }

    /// Homepages are only shown and opened in a browser, but still must be http(s) on a real host.
    static func validHomepage(_ s: String) -> URL? {
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              c.percentEncodedUser == nil, let host = c.percentEncodedHost,
              (try? RadioURLPolicy.validateHost(host)) != nil else { return nil }
        return c.url
    }

    /// Trims, removes control characters (titles reach the marquee and Now Playing) and caps the length.
    static func cleanText(_ s: String) -> String? {
        let scalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let t = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > maxTitleLength ? String(t.prefix(maxTitleLength)) : t
    }

    static func parseDate(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        return try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
