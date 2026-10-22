// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import CryptoKit
import Foundation
import Resolver

/// `build`, `lint`, `split` and `bump`: the curated sources ↔ `catalog/feed.json` (docs/catalog.md).
enum BuildCommands {
    // MARK: build

    static let buildUsage = """
    usage: catalog-tool build [<catalog-dir>] [--check] [--offline] [--force]
      Builds catalog/genres/*.json + release.json + engine.json (+ pins.json) into catalog/feed.json, byte-for-byte
      deterministic. A pinned yt-dlp version missing from pins.json has its SHA-256 fetched from upstream's
      SHA2-256SUMS (unless --offline) and recorded in pins.json. Refuses when lint finds errors (--force overrides).
      --check: write nothing; exit 1 if feed.json is not what the sources build.
    """

    static func build(_ args: ToolArgs) async -> Int32 {
        guard let dir = catalogDirectory(args.positionals.first) else { stderr(buildUsage); return 64 }
        var source: CatalogSource
        do { source = try CatalogSource.load(directory: dir) } catch { stderr("build: \(error)"); return 1 }

        let missing = CatalogBuilder.missingPins(source)
        if !missing.isEmpty {
            if args.flag("offline") || args.flag("check") {
                stderr("build: pins.json has no SHA-256 for \(missing.joined(separator: ", ")) (run without --offline/--check)")
                return 1
            }
            for version in missing {
                do {
                    let sha = try await Upstream.zipSHA256(version: version)
                    source.pins.sha256[version] = sha
                    stderr("build: yt-dlp \(version) \(PinLock.asset) sha256 \(sha) (from upstream SHA2-256SUMS)")
                } catch {
                    stderr("build: cannot fetch SHA2-256SUMS for \(version): \(error)")
                    return 1
                }
            }
            if !args.flag("check") {
                do {
                    try Data((source.pins.json.pretty() + "\n").utf8).write(to: dir.appending(path: CatalogSource.pinsFile),
                                                                          options: .atomic)
                } catch { stderr("build: cannot write pins.json: \(error)"); return 1 }
            }
        }

        let issues = CatalogLint.lint(source: source, existingFeed: nil)
        let errors = issues.filter { $0.severity == .error }
        for i in issues { stderr(i.description) }
        if !errors.isEmpty && !args.flag("force") {
            stderr("build: \(errors.count) lint error(s); fix them or pass --force")
            return 1
        }

        let feed: Data
        do { feed = try CatalogBuilder.build(source) } catch { stderr("build: \(error)"); return 1 }
        let feedURL = dir.appending(path: CatalogSource.feedFile)
        let existing = try? Data(contentsOf: feedURL)
        let digest = SHA256.hash(data: feed).map { String(format: "%02x", $0) }.joined()
        let doc = try? FeedDecoder.decode(feed).document
        let counts = "\(doc?.catalog.genres.count ?? 0) genres, \(doc?.catalog.streams.count ?? 0) streams"
        let summary = "r\(doc?.revision ?? -1), \(counts), \(feed.count) bytes, sha256 \(digest)"
        if args.flag("check") {
            guard existing == feed else { stderr("build --check: catalog/feed.json is stale (\(summary))"); return 1 }
            print("feed.json is up to date: \(summary)")
            return 0
        }
        if existing == feed {
            print("feed.json unchanged: \(summary)")
        } else {
            do { try feed.write(to: feedURL, options: .atomic) } catch { stderr("build: cannot write feed.json: \(error)"); return 1 }
            print("wrote \(feedURL.path): \(summary)")
            if FileManager.default.fileExists(atPath: feedURL.path + ".sig") {
                stderr("build: feed.json.sig no longer matches; run catalog-tool sign")
            }
        }
        return 0
    }

    // MARK: lint

    static let lintUsage = """
    usage: catalog-tool lint [<catalog-dir> | <feed.json>] [--json] [--strict] [--dns] [--rule release|m1]
      Schema, DESIGN §7.1 canonicaliser and radio URL policy, duplicate IDs, DESIGN §7.2 engine strings, the
      coverage rule (default release: >= 15 active streams, >= 2 radio stations from >= 2 broadcasters, >= 2 source
      types per genre), the canary, expiry, and (for a directory) that feed.json matches a fresh build.
      --dns also resolves every radio host and requires public addresses only. Exit 1 on errors (--strict: warnings).
    """

    struct LintReport: Encodable {
        struct Item: Encodable {
            var rule: String
            var severity: String
            var location: String
            var message: String
        }
        var target: String
        var errors: Int
        var warnings: Int
        var issues: [Item]
    }

    static func lint(_ args: ToolArgs) async -> Int32 {
        let target = args.positionals.first.map { URL(filePath: ($0 as NSString).expandingTildeInPath) } ?? catalogDirectory(nil)
        guard let target else { stderr(lintUsage); return 64 }
        let rule: CoverageRule = args.string("rule") == "m1" ? .m1 : .release
        var issues: [LintIssue]
        var feedData: Data?
        if isDirectory(target) {
            do {
                let source = try CatalogSource.load(directory: target)
                let existing = try? Data(contentsOf: target.appending(path: CatalogSource.feedFile))
                issues = CatalogLint.lint(source: source, existingFeed: existing, rule: rule)
                feedData = existing
            } catch {
                issues = [LintIssue(.json, target.path, "\(error)")]
            }
        } else {
            guard let data = try? Data(contentsOf: target) else { stderr("lint: cannot read \(target.path)"); return 1 }
            issues = CatalogLint.lint(feed: data, location: target.lastPathComponent, rule: rule)
            feedData = data
        }
        if args.flag("dns"), let feedData, let doc = try? FeedDecoder.decode(feedData).document {
            issues += await dnsIssues(doc)
        }
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.count - errors
        if args.flag("json") {
            printJSON(LintReport(target: target.path, errors: errors, warnings: warnings, issues: issues.map {
                .init(rule: $0.rule.rawValue, severity: $0.severity.rawValue, location: $0.location, message: $0.message)
            }))
        } else {
            for i in issues { print(i.description) }
            print("lint \(target.path): \(errors) error(s), \(warnings) warning(s)")
        }
        return errors > 0 || (args.flag("strict") && warnings > 0) ? 1 : 0
    }

    /// Every radio host must resolve, to public addresses only (what the app checks before playback, DESIGN §7.1).
    static func dnsIssues(_ doc: FeedDocument) async -> [LintIssue] {
        var out: [LintIssue] = []
        let resolver = SystemHostResolver()
        for s in doc.catalog.streams where s.isRadio {
            do { _ = try await RadioHostCheck.check(s.url, resolver: resolver) } catch {
                out.append(LintIssue(.radioURL, "dns", "\(s.id): \(error)"))
            }
        }
        return out
    }

    // MARK: split

    static let splitUsage = """
    usage: catalog-tool split <feed.json> --out <catalog-dir>
      One-time migration: writes release.json, engine.json, pins.json and genres/<id>.json from a feed.json in the
      canonical layout, then checks that building them reproduces the input byte-for-byte.
    """

    static func split(_ args: ToolArgs) -> Int32 {
        guard let input = args.positionals.first, let out = args.string("out") else { stderr(splitUsage); return 64 }
        let outDir = URL(filePath: (out as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        do {
            let data = try Data(contentsOf: URL(filePath: input))
            let source = try CatalogBuilder.split(feed: data)
            try source.write(to: outDir)
            let rebuilt = try CatalogBuilder.build(try CatalogSource.load(directory: outDir))
            guard rebuilt == data else {
                stderr("split: wrote \(outDir.path), but the build differs from \(input) (not in the canonical layout?)")
                return 1
            }
            print("split \(input) into \(source.genres.count) genre files in \(outDir.path); the build reproduces it byte-for-byte")
            return 0
        } catch {
            stderr("split: \(error)")
            return 1
        }
    }

    // MARK: bump

    static let bumpUsage = """
    usage: catalog-tool bump [<catalog-dir>] [--expires-days 182]
      Before publishing: revision + 1, generatedAt = now, expiresAt = now + N days (midnight UTC), in release.json.
    """

    static func bump(_ args: ToolArgs) -> Int32 {
        guard let dir = catalogDirectory(args.positionals.first) else { stderr(bumpUsage); return 64 }
        let url = dir.appending(path: CatalogSource.releaseFile)
        do {
            let json = try OrderedJSON.parse(try Data(contentsOf: url))
            guard let revision = json["revision"]?.intLiteral else { stderr("bump: release.json has no integer revision"); return 1 }
            let now = Date()
            let days = args.int("expires-days") ?? 182
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            let expires = calendar.startOfDay(for: now.addingTimeInterval(TimeInterval(days) * 86_400))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            func stamp(_ d: Date) -> String { formatter.string(from: d) }
            let bumped = json.setting("revision", to: .number(String(revision + 1)))
                .setting("generatedAt", to: .string(stamp(now)))
                .setting("expiresAt", to: .string(stamp(expires)))
            try Data((bumped.pretty() + "\n").utf8).write(to: url, options: .atomic)
            print("release.json: revision \(revision + 1), generatedAt \(stamp(now)), expiresAt \(stamp(expires))")
            print("now run catalog-tool build (and sign before publishing)")
            return 0
        } catch {
            stderr("bump: \(error)")
            return 1
        }
    }
}

/// Upstream yt-dlp release metadata for `build`.
enum Upstream {
    /// The `yt-dlp_macos.zip` line of a release's `SHA2-256SUMS` (DESIGN §6.1).
    static func zipSHA256(version: String) async throws -> String {
        let text = try await GitHubReleases(downloader: HTTPDownloader(userAgent: toolUserAgent)).checksums(version: version)
        guard let sha = SHA256Sums(parsing: text)[PinLock.asset] else {
            throw EngineStoreError.checksumMissing(PinLock.asset)
        }
        return sha
    }
}
