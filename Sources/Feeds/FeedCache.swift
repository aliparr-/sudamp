// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The last accepted remote document, kept in `<profile>/feed/` (DESIGN §7.2, §10):
/// `feed.json` (the exact fetched bytes), `feed.json.sig` and `meta.json` `{etag, fetchedAt, revision}`.
///
/// The directory is user-writable, so a cached copy is re-verified every time it is read; one that fails is treated
/// as absent (and its ETag is not sent, so the next fetch downloads a fresh copy).
public struct FeedCache: Sendable {
    /// `meta.json`.
    public struct Meta: Codable, Sendable, Equatable {
        /// The server's ETag for the cached body, sent as `If-None-Match`.
        public var etag: String?
        /// When the server last confirmed the cached body (a 200, or a 304, which updates only this field).
        public var fetchedAt: Date
        /// The cached document's revision (the anti-rollback floor for fetched documents).
        public var revision: Int

        public init(etag: String?, fetchedAt: Date, revision: Int) {
            self.etag = etag
            self.fetchedAt = fetchedAt
            self.revision = revision
        }
    }

    /// A cached document as stored (not yet verified).
    public struct Entry: Sendable, Equatable {
        public var body: Data
        public var signature: Data
        public var meta: Meta
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var feedFile: URL { directory.appending(path: "feed.json") }
    public var signatureFile: URL { directory.appending(path: "feed.json.sig") }
    public var metaFile: URL { directory.appending(path: "meta.json") }

    /// `meta.json`, if present and readable.
    public func readMeta() -> Meta? {
        guard let data = try? Data(contentsOf: metaFile) else { return nil }
        return try? Self.decoder.decode(Meta.self, from: data)
    }

    /// All three files, or nil if any is missing or unreadable.
    public func read() -> Entry? {
        guard let meta = readMeta(), let body = try? Data(contentsOf: feedFile),
              let signature = try? Data(contentsOf: signatureFile) else { return nil }
        return Entry(body: body, signature: signature, meta: meta)
    }

    /// Replaces the cached document. Each file is written atomically; `meta.json` goes last, so a crash in between
    /// leaves a body/signature pair that fails verification (and is then ignored) rather than a stale ETag.
    public func store(body: Data, signature: Data, meta: Meta) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: metaFile)
        try signature.write(to: signatureFile, options: .atomic)
        try body.write(to: feedFile, options: .atomic)
        try writeMeta(meta)
    }

    /// A 304: only `fetchedAt` moves.
    public func touch(fetchedAt: Date) throws {
        guard var meta = readMeta() else { return }
        meta.fetchedAt = fetchedAt
        try writeMeta(meta)
    }

    /// Removes the cached document (it failed verification or decoding).
    public func clear() {
        for f in [metaFile, feedFile, signatureFile] { try? FileManager.default.removeItem(at: f) }
    }

    private func writeMeta(_ meta: Meta) throws {
        try Self.encoder.encode(meta).write(to: metaFile, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
