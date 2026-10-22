// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The curated sources `catalog-tool build` turns into `catalog/feed.json` (docs/catalog.md):
///
/// ```
/// catalog/release.json      {"schema", "revision", "generatedAt", "expiresAt"}   the envelope; bump per publish
/// catalog/engine.json       the feed's `engine` section; `pin` names a version only
/// catalog/pins.json         {"asset": "yt-dlp_macos.zip", "sha256": {"<version>": "<hex>"}}  checksum lock
/// catalog/genres/<id>.json  {"id", "name", "order", "streams": [ … ]}  one genre and its streams
/// catalog/feed.json         generated: never edit by hand
/// ```
///
/// A stream in `genres/<id>.json` belongs to that genre; it lists `"genres"` only to join more than one.
public struct CatalogSource: Sendable, Equatable {
    /// One parsed file and the name it is reported under.
    public struct File: Sendable, Equatable {
        public var name: String
        public var json: OrderedJSON

        public init(name: String, json: OrderedJSON) {
            self.name = name
            self.json = json
        }
    }

    public static let releaseFile = "release.json"
    public static let engineFile = "engine.json"
    public static let pinsFile = "pins.json"
    public static let genresDirectory = "genres"
    public static let feedFile = "feed.json"

    public var release: File
    public var engine: File
    public var pins: PinLock
    /// Sorted by file name; the build orders genres by `order`, then id.
    public var genres: [File]

    public init(release: File, engine: File, pins: PinLock, genres: [File]) {
        self.release = release
        self.engine = engine
        self.pins = pins
        self.genres = genres.sorted { $0.name < $1.name }
    }

    /// Reads `catalog/`.
    public static func load(directory: URL) throws(CatalogBuildError) -> CatalogSource {
        func read(_ name: String) throws(CatalogBuildError) -> File {
            let url = directory.appending(path: name)
            guard let data = try? Data(contentsOf: url) else { throw .file(name, "cannot read") }
            do { return File(name: name, json: try OrderedJSON.parse(data)) } catch { throw .file(name, error.description) }
        }
        let release = try read(releaseFile)
        let engine = try read(engineFile)
        let pins = try PinLock(file: try read(pinsFile))
        let dir = directory.appending(path: genresDirectory, directoryHint: .isDirectory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            throw .file(genresDirectory, "cannot list")
        }
        var genres: [File] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            genres.append(try read("\(genresDirectory)/\(name)"))
        }
        return CatalogSource(release: release, engine: engine, pins: pins, genres: genres)
    }

    /// Writes the source files (`catalog-tool split`, the one-time migration from a hand-edited `feed.json`).
    public func write(to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appending(path: Self.genresDirectory, directoryHint: .isDirectory),
                               withIntermediateDirectories: true)
        func put(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: directory.appending(path: name), options: .atomic)
        }
        try put(release.name, release.json.pretty() + "\n")
        try put(engine.name, engine.json.pretty() + "\n")
        try put(Self.pinsFile, pins.json.pretty() + "\n")
        for g in genres { try put(g.name, CatalogLayout.genreFileText(g.json)) }
    }
}

/// `catalog/pins.json`: the SHA-256 of `yt-dlp_macos.zip` for each pinned version, copied from upstream's
/// `SHA2-256SUMS` by `catalog-tool build` (DESIGN §6.1) and committed, so builds are offline and reproducible.
public struct PinLock: Sendable, Equatable {
    public static let asset = "yt-dlp_macos.zip"

    /// Version → lower-case hex SHA-256.
    public var sha256: [String: String]

    public init(sha256: [String: String] = [:]) { self.sha256 = sha256 }

    init(file: CatalogSource.File) throws(CatalogBuildError) {
        guard file.json["asset"]?.stringValue == Self.asset, let map = file.json["sha256"]?.members else {
            throw .file(file.name, "needs {\"asset\": \"\(Self.asset)\", \"sha256\": {\"<version>\": \"<hex>\"}}")
        }
        var out: [String: String] = [:]
        for m in map {
            guard EngineValidation.isValidEngineVersion(m.key), let h = m.value.stringValue, EngineValidation.isValidSHA256(h) else {
                throw .file(file.name, "invalid entry \(m.key)")
            }
            out[m.key] = h
        }
        sha256 = out
    }

    /// Sorted by version, newest last.
    public var json: OrderedJSON {
        .object([
            .init("asset", .string(Self.asset)),
            .init("sha256", .object(sha256.sorted { $0.key < $1.key }.map { .init($0.key, .string($0.value)) })),
        ])
    }
}

public enum CatalogBuildError: Error, Sendable, Equatable, CustomStringConvertible {
    case file(String, String)
    /// `engine.json` pins a version `pins.json` has no checksum for (`catalog-tool build` fetches it).
    case missingPin(String)

    public var description: String {
        switch self {
        case .file(let f, let m): "\(f): \(m)"
        case .missingPin(let v): "pins.json has no SHA-256 for yt-dlp \(v) (run catalog-tool build online to fetch it)"
        }
    }
}

/// Key orders and line layout of the generated files (one item per line, so diffs stay readable).
public enum CatalogLayout {
    public static let releaseKeys = ["schema", "revision", "generatedAt", "expiresAt"]
    public static let genreFileKeys = ["id", "name", "order", "streams"]
    public static let genreKeys = ["id", "name", "order"]
    /// Every stream field the feed decoder reads, in output order.
    public static let streamKeys = ["id", "source", "ref", "kind", "title", "creator", "genres", "durationSec", "homepage",
                                    "weight"]
    public static let engineKeys = ["minAppVersion", "pin", "block", "sources", "nightlyEscalation", "fastStartRank",
                                    "clients", "formats", "extractorArgs", "mediaHosts", "canary"]

    /// `members` reordered to `order`; unknown keys are dropped (lint reports them).
    static func ordered(_ json: OrderedJSON, _ order: [String]) -> OrderedJSON {
        .object(order.compactMap { k in json[k].map { OrderedJSON.Member(k, $0) } })
    }

    /// A genre source file: envelope members one per line, each stream on one line.
    public static func genreFileText(_ json: OrderedJSON) -> String {
        var lines: [String] = []
        let members = json.members ?? []
        for m in members {
            if m.key == "streams", let streams = m.value.elements {
                if streams.isEmpty { lines.append("  \"streams\": []"); continue }
                let items = streams.map { "    " + ordered($0, streamKeys).compact }
                lines.append("  \"streams\": [\n" + items.joined(separator: ",\n") + "\n  ]")
            } else {
                lines.append("  " + OrderedJSON.quote(m.key) + ": " + m.value.pretty(level: 1))
            }
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }
}

/// `catalog-tool build`: the source files → `feed.json` bytes. Deterministic: the same sources always give the same
/// bytes (no clock, no network; checksums come from `pins.json`).
public enum CatalogBuilder {
    /// Pinned versions `pins.json` lacks.
    public static func missingPins(_ source: CatalogSource) -> [String] {
        guard let v = source.engine.json["pin"]?["version"]?.stringValue else { return [] }
        return source.pins.sha256[v] == nil ? [v] : []
    }

    public static func build(_ source: CatalogSource) throws(CatalogBuildError) -> Data {
        Data(try buildText(source).utf8)
    }

    public static func buildText(_ source: CatalogSource) throws(CatalogBuildError) -> String {
        guard source.release.json.members != nil else { throw .file(source.release.name, "not an object") }
        guard source.engine.json.members != nil else { throw .file(source.engine.name, "not an object") }

        // Genres by (order, id); streams in genre order, then file order.
        var genres: [(order: Int, id: String, json: OrderedJSON, streams: [OrderedJSON])] = []
        for file in source.genres {
            guard let id = file.json["id"]?.stringValue else { throw .file(file.name, "missing \"id\"") }
            let order = file.json["order"]?.intLiteral ?? 0
            guard let streams = (file.json["streams"] ?? .array([])).elements else {
                throw .file(file.name, "\"streams\" is not a list")
            }
            let filled = streams.map { s in s["genres"] == nil ? s.setting("genres", to: .array([.string(id)])) : s }
            genres.append((order, id, CatalogLayout.ordered(file.json, CatalogLayout.genreKeys), filled))
        }
        genres.sort { ($0.order, $0.id) < ($1.order, $1.id) }

        var engine = CatalogLayout.ordered(source.engine.json, CatalogLayout.engineKeys)
        if let pin = engine["pin"], pin != .null {
            guard let version = pin["version"]?.stringValue else { throw .file(source.engine.name, "pin needs a version") }
            guard let sha = source.pins.sha256[version] else { throw .missingPin(version) }
            if let given = pin["sha256"]?.stringValue, given != sha {
                throw .file(source.engine.name, "pin sha256 differs from pins.json for \(version)")
            }
            engine = engine.setting("pin", to: .object([.init("version", .string(version)), .init("sha256", .string(sha))]))
        }

        var out = "{\n"
        for key in CatalogLayout.releaseKeys {
            guard let v = source.release.json[key] else { continue }
            out += "  \(OrderedJSON.quote(key)): \(v.compact),\n"
        }
        out += "  \"catalog\": {\n"
        out += "    \"genres\": " + list(genres.map { $0.json.compact }) + ",\n"
        let streams = genres.flatMap(\.streams).map { CatalogLayout.ordered($0, CatalogLayout.streamKeys).compact }
        out += "    \"streams\": " + list(streams) + "\n"
        out += "  },\n"
        out += "  \"engine\": " + engine.pretty(level: 1) + "\n"
        out += "}\n"
        return out
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "[]" : "[\n" + items.map { "      " + $0 }.joined(separator: ",\n") + "\n    ]"
    }

    /// The inverse of `build` for a feed in the canonical layout (`catalog-tool split`): one file per genre (a stream
    /// goes to its first genre's file), `engine.json` without the pin's checksum, which moves to `pins.json`.
    public static func split(feed data: Data) throws(CatalogBuildError) -> CatalogSource {
        let feed: OrderedJSON
        do { feed = try OrderedJSON.parse(data) } catch { throw .file(CatalogSource.feedFile, error.description) }
        guard let catalog = feed["catalog"], let genres = catalog["genres"]?.elements,
              let streams = catalog["streams"]?.elements else { throw .file(CatalogSource.feedFile, "missing catalog") }
        let release = OrderedJSON.object(CatalogLayout.releaseKeys.compactMap { k in feed[k].map { .init(k, $0) } })
        var engine = feed["engine"] ?? .object([])
        var pins = PinLock()
        if let pin = engine["pin"], let v = pin["version"]?.stringValue {
            if let sha = pin["sha256"]?.stringValue { pins.sha256[v] = sha }
            engine = engine.setting("pin", to: .object([.init("version", .string(v))]))
        }
        var files: [CatalogSource.File] = []
        let known = Set(genres.compactMap { $0["id"]?.stringValue })
        if let orphan = streams.first(where: { s in !known.contains(s["genres"]?.elements?.first?.stringValue ?? "") }) {
            throw .file(CatalogSource.feedFile, "stream \(orphan["id"]?.stringValue ?? "?")'s first genre is not in the genre list")
        }
        for g in genres {
            guard let id = g["id"]?.stringValue else { throw .file(CatalogSource.feedFile, "genre without id") }
            let mine = streams.filter { $0["genres"]?.elements?.first?.stringValue == id }.map { s in
                s["genres"] == .array([.string(id)]) ? s.removing("genres") : s
            }
            files.append(.init(name: "\(CatalogSource.genresDirectory)/\(id).json",
                               json: CatalogLayout.ordered(g, CatalogLayout.genreKeys).setting("streams", to: .array(mine))))
        }
        return CatalogSource(release: .init(name: CatalogSource.releaseFile, json: release),
                             engine: .init(name: CatalogSource.engineFile, json: engine), pins: pins, genres: files)
    }
}
