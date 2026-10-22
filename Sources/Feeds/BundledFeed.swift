// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation

/// Where a feed document came from (DESIGN §7.2).
public enum FeedOrigin: String, Sendable, Codable {
    /// `Contents/Resources/feed.json` (sealed by the app's signature) or, in development, `catalog/feed.json`.
    case bundled
    /// The last fetched document kept in `<profile>/feed/`, read back at launch.
    case cached
    /// Fetched from the feed host by this process.
    case fetched
}

/// A validated feed document and what validation had to skip.
public struct LoadedFeed: Sendable {
    public let document: FeedDocument
    public let origin: FeedOrigin
    public let url: URL
    public let dropped: [DroppedItem]
    public let engineIssues: [EngineIssue]
    /// Genres below the M1 coverage rule. Reported, not fatal: a thin genre still plays what it has.
    public let coverage: [CoverageViolation]

    public init(document: FeedDocument, origin: FeedOrigin, url: URL, dropped: [DroppedItem] = [],
                engineIssues: [EngineIssue] = [], coverage: [CoverageViolation] = []) {
        self.document = document
        self.origin = origin
        self.url = url
        self.dropped = dropped
        self.engineIssues = engineIssues
        self.coverage = coverage
    }

    /// One line per problem, for the log and `sudamp-dev`.
    public var warnings: [String] {
        dropped.map(\.description) + engineIssues.map(\.description) + coverage.map(\.description)
    }
}

public enum FeedLoadError: Error, Equatable, Sendable, CustomStringConvertible {
    case notFound([String])
    case unreadable(String)
    case invalid(String, FeedError)

    public var description: String {
        switch self {
        case .notFound(let paths): "no feed.json found (looked in \(paths.joined(separator: ", ")))"
        case .unreadable(let path): "cannot read \(path)"
        case .invalid(let path, let e): "\(path): \(e)"
        }
    }
}

/// The bundled feed: always valid, never expires, the fallback for every remote failure (DESIGN §7.2).
public enum BundledFeed {
    public static let fileName = "feed.json"

    /// Where to look, in order: an explicit override, the app bundle's resources, then `catalog/feed.json` in a
    /// development checkout found by walking up from the working directory and from the executable (so
    /// `swift run sudamp-dev` and `.build/debug/sudamp-dev` both work from anywhere inside the repo).
    public static func candidates(override: URL? = nil, resourceURL: URL?, executableURL: URL?,
                                  currentDirectory: URL) -> [URL] {
        var out: [URL] = []
        if let override { out.append(override) }
        if let resourceURL { out.append(resourceURL.appending(path: fileName)) }
        for start in [currentDirectory, executableURL?.deletingLastPathComponent()].compactMap({ $0 }) {
            var dir = start.standardizedFileURL
            for _ in 0..<8 {
                out.append(dir.appending(path: "catalog/\(fileName)"))
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The first existing candidate for this process.
    public static func locate(override: URL? = nil, bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        let cwd = URL(filePath: fileManager.currentDirectoryPath, directoryHint: .isDirectory)
        return candidates(override: override, resourceURL: bundle.resourceURL, executableURL: bundle.executableURL,
                          currentDirectory: cwd).first { fileManager.isReadableFile(atPath: $0.path) }
    }

    /// Reads and validates a feed file. Envelope errors (bad JSON, unknown schema) throw; bad items are dropped.
    public static func load(from url: URL, origin: FeedOrigin = .bundled,
                            previousEngine: EngineConfig = .defaults) throws(FeedLoadError) -> LoadedFeed {
        guard let data = try? Data(contentsOf: url) else { throw .unreadable(url.path) }
        return try load(data: data, url: url, origin: origin, previousEngine: previousEngine)
    }

    /// Validates feed bytes already in memory (a fetched or cached document); `url` is only reported.
    public static func load(data: Data, url: URL, origin: FeedOrigin,
                            previousEngine: EngineConfig = .defaults) throws(FeedLoadError) -> LoadedFeed {
        let result: FeedDecodeResult
        do { result = try FeedDecoder.decode(data, previousEngine: previousEngine) } catch { throw .invalid(url.path, error) }
        let coverage = CoverageValidator.check(result.document.catalog, engine: result.document.engine, rule: .m1)
        return LoadedFeed(document: result.document, origin: origin, url: url, dropped: result.dropped,
                          engineIssues: result.engineIssues, coverage: coverage)
    }

    /// Locates and loads the bundled feed, logging what validation skipped.
    public static func loadDefault(override: URL? = nil, bundle: Bundle = .main) throws(FeedLoadError) -> LoadedFeed {
        guard let url = locate(override: override, bundle: bundle) else {
            let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
            throw .notFound(candidates(override: override, resourceURL: bundle.resourceURL,
                                       executableURL: bundle.executableURL, currentDirectory: cwd).map(\.path))
        }
        let feed = try load(from: url)
        let log = Log.logger("feed")
        for w in feed.warnings { log.warning("\(w, privacy: .public)") }
        log.info("bundled feed r\(feed.document.revision) from \(url.path, privacy: .public): \(feed.document.catalog.streams.count) streams")
        return feed
    }
}
