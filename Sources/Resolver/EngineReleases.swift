// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation

/// Where engine releases come from. Production is `GitHubReleases`; tests serve local fixtures.
public protocol EngineReleaseSource: Sendable {
    /// The GitHub `owner/repo` (or a stand-in): reports use it, and `_update_spec` `lockV2` lines match on it.
    var name: String { get }
    /// The newest release tag.
    func latestVersion() async throws -> String
    /// Recent release tags, newest first (used only when `latest` is blocked or above a lock).
    func recentVersions() async throws -> [String]
    /// The `_update_spec` text, or nil when the asset doesn't exist.
    func updateSpec() async throws -> String?
    /// The release's `SHA2-256SUMS` text.
    func checksums(version: String) async throws -> String
    /// Streams a release asset into `file`, resuming from the bytes already there.
    func download(asset: String, version: String, to file: URL,
                  progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> DownloadOutcome
}

public enum EngineReleaseError: Error, Sendable, Equatable {
    case noLatestRedirect
    case unparsableTag(String)
}

/// Upstream GitHub releases without the rate-limited REST API (60 requests/hour unauthenticated):
/// `releases/latest` answers with a redirect to `releases/tag/<ver>`, `releases.atom` lists recent tags, and
/// assets come from `releases/download/<ver>/<name>` (which redirects to GitHub's asset CDN).
public struct GitHubReleases: EngineReleaseSource {
    public static let stableRepo = "yt-dlp/yt-dlp"
    /// Nightly builds (tags `YYYY.MM.DD.HHMMSS`) also ship `yt-dlp_macos.zip` + `SHA2-256SUMS` (R1, 2026-10-22).
    public static let nightlyRepo = "yt-dlp/yt-dlp-nightly-builds"

    public let repo: String
    public let downloader: HTTPDownloader

    public init(repo: String = "yt-dlp/yt-dlp", downloader: HTTPDownloader = HTTPDownloader()) {
        self.repo = repo
        self.downloader = downloader
    }

    public var name: String { repo }
    private var base: URL { URL(string: "https://github.com/\(repo)/releases")! }

    public func latestVersion() async throws -> String {
        guard let location = try await downloader.redirectLocation(of: base.appending(path: "latest")) else {
            throw EngineReleaseError.noLatestRedirect
        }
        guard let tag = Self.tag(fromReleaseURL: location) else {
            throw EngineReleaseError.unparsableTag(location.absoluteString)
        }
        return tag
    }

    public func recentVersions() async throws -> [String] {
        let atom = try await downloader.data(from: URL(string: "https://github.com/\(repo)/releases.atom")!)
        return Self.tags(fromAtom: String(decoding: atom, as: UTF8.self))
    }

    public func updateSpec() async throws -> String? {
        let url = base.appending(path: "latest/download/_update_spec")
        return try await downloader.optionalData(from: url).map { String(decoding: $0, as: UTF8.self) }
    }

    public func checksums(version: String) async throws -> String {
        String(decoding: try await downloader.data(from: assetURL("SHA2-256SUMS", version: version)), as: UTF8.self)
    }

    public func download(asset: String, version: String, to file: URL,
                         progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> DownloadOutcome {
        try await downloader.download(assetURL(asset, version: version), to: file, progress: progress)
    }

    public func assetURL(_ name: String, version: String) -> URL {
        base.appending(path: "download").appending(path: version).appending(path: name)
    }

    /// `…/releases/tag/<ver>` → `<ver>` when it is a valid engine version.
    static func tag(fromReleaseURL url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.lastIndex(of: "tag"), i + 1 < parts.count, EngineVersion(parts[i + 1]) != nil else {
            return nil
        }
        return parts[i + 1]
    }

    /// Release tags linked from an Atom feed, newest first, deduplicated.
    static func tags(fromAtom xml: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"/releases/tag/([0-9]{4}\.[0-9]{2}\.[0-9]{2}(?:\.[0-9]+)?)""#)
        var seen = Set<String>()
        var tags: [String] = []
        for m in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let r = Range(m.range(at: 1), in: xml) else { continue }
            let tag = String(xml[r])
            if seen.insert(tag).inserted { tags.append(tag) }
        }
        return tags.sorted { (EngineVersion($0)!) > (EngineVersion($1)!) }
    }
}
