// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
import Resolver

/// `catalog-tool discover --genre <tag>` (DESIGN §7.3): candidate streams for a human to review, printed as JSON in
/// the genre-file stream format plus an `evidence` object. Nothing is written to `catalog/`.
/// - radio-browser.info by tag (votes order, `hidebroken`), each URL checked by RadioCheck (public DNS, HTTP 200,
///   audio content type, chained frames);
/// - SoundCloud `scsearch` through the profile's engine (flat, one request);
/// - Mixcloud's no-auth `api.mixcloud.com/discover/<tag>/popular/`, exclusive uploads skipped.
/// YouTube is not searched (its request budget is kept for `probe`).
enum DiscoverCommand {
    static let usage = """
    usage: catalog-tool discover --genre <tag> [--sources radio,soundcloud,mixcloud] [--limit 10] [--profile <dir>]
                                 [--catalog <dir>] [--allow-http] [--no-verify]
      SoundCloud needs --profile with an installed engine. Candidates still need the DESIGN §7.3 checks (SoundCloud
      policy ALLOW/MONETIZE and full_duration, Mixcloud restrictedReason via probe, broadcaster credit) before
      they go into catalog/genres/<id>.json.
    """

    struct Candidate: Encodable {
        var id: String
        var source: String
        var ref: String
        var kind: String
        var title: String
        var creator: String
        var genres: [String]
        var durationSec: Int?
        var homepage: String?
        var weight: Double
        var evidence: [String: String]
    }

    struct Output: Encodable {
        var genre: String
        var candidates: [Candidate]
        var notes: [String]
    }

    static func run(_ args: ToolArgs) async -> Int32 {
        guard let tag = args.string("genre"), !tag.isEmpty else { stderr(usage); return 64 }
        let sources = Set(args.list("sources") ?? ["radio", "soundcloud", "mixcloud"])
        let limit = max(1, min(args.int("limit") ?? 10, 50))
        let genreID = slug(tag, max: 32)
        var out = Output(genre: genreID, candidates: [], notes: [])
        // What the catalog already has (by ID and radio URL) is not a candidate.
        var known = Set<String>()
        if let dir = catalogDirectory(args.string("catalog")),
           let doc = try? FeedDecoder.decode(Data(contentsOf: dir.appending(path: CatalogSource.feedFile))).document {
            known = Set(doc.catalog.streams.flatMap { [$0.id.rawValue, $0.ref] })
        }
        if sources.contains("radio") {
            out.candidates += await radio(tag: tag, genre: genreID, limit: limit, allowHTTP: args.flag("allow-http"),
                                          verify: !args.flag("no-verify"), known: known, notes: &out.notes)
        }
        if sources.contains("mixcloud") {
            out.candidates += await mixcloud(tag: tag, genre: genreID, limit: limit, known: known, notes: &out.notes)
        }
        if sources.contains("soundcloud") {
            if let profile = args.string("profile") {
                out.candidates += await soundcloud(tag: tag, genre: genreID, limit: limit, profile: profile, known: known,
                                                   notes: &out.notes)
            } else {
                out.notes.append("soundcloud skipped: pass --profile <dir> with an installed engine")
            }
        }
        if !known.isEmpty { out.notes.append("items already in the catalog are left out") }
        printJSON(out)
        return 0
    }

    /// `Deep House!` → `deep-house`: ASCII words joined by single hyphens, at most `max` characters, never ending in a
    /// hyphen (a valid genre ID or radio slug).
    static func slug(_ s: String, max: Int = 48) -> String {
        let words = s.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        var out = String(words.joined(separator: "-").prefix(max))
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    static let soundCloudTodo = "check policy ALLOW/MONETIZE, |duration - full_duration| < 2 s and an AAC transcoding (DESIGN §7.3)"

    /// Titles reach the marquee: trimmed and capped like the feed decoder does.
    static func clean(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FeedDecoder.maxTitleLength))
    }

    static func getJSON(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(toolUserAgent, forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0, url: url.absoluteString)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: radio-browser.info

    static func radio(tag: String, genre: String, limit: Int, allowHTTP: Bool, verify: Bool, known: Set<String>,
                      notes: inout [String]) async -> [Candidate] {
        // A mirror from the server list (sorted, so runs are repeatable), else de1.
        var server = "de1.api.radio-browser.info"
        if let list = try? await getJSON(URL(string: "https://all.api.radio-browser.info/json/servers")!) as? [[String: Any]] {
            server = list.compactMap { $0["name"] as? String }.sorted().first ?? server
        }
        var c = URLComponents(string: "https://\(server)/json/stations/bytag/")!
        c.path += tag
        c.queryItems = [.init(name: "order", value: "votes"), .init(name: "reverse", value: "true"),
                        .init(name: "hidebroken", value: "true"), .init(name: "limit", value: "\(limit * 4)")]
        guard let url = c.url, let stations = try? await getJSON(url) as? [[String: Any]] else {
            notes.append("radio-browser: request failed")
            return []
        }
        var out: [Candidate] = []
        var seenURLs = Set<String>()
        for s in stations where out.count < limit {
            guard let name = (s["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let raw = (s["url_resolved"] as? String) ?? (s["url"] as? String) else { continue }
            let id = "radio:\(slug(name))"
            guard let valid = try? RadioURLPolicy.validate(raw), !known.contains(valid.absoluteString), !known.contains(id),
                  seenURLs.insert(valid.absoluteString).inserted else { continue }
            if !allowHTTP && valid.scheme != "https" { continue }
            if (valid.host ?? "").hasSuffix("somafm.com") { continue }
            var evidence: [String: String] = [
                "votes": "\(s["votes"] ?? "")", "codec": "\(s["codec"] ?? "")", "bitrate": "\(s["bitrate"] ?? "")",
                "country": "\(s["countrycode"] ?? "")", "tags": "\(s["tags"] ?? "")", "radiobrowser": server,
            ]
            if verify {
                let check = await RadioCheck.check(valid)
                evidence["check"] = check.ok
                    ? "ok: HTTP \(check.status ?? 0), \(check.contentType ?? "?"), \(check.frames ?? 0) \(check.format ?? "") frames"
                    : "FAILED: \(check.error ?? "?")"
                if let icy = check.icyName { evidence["icyName"] = icy }
                if !check.ok { continue }
            }
            let homepage = (s["homepage"] as? String).flatMap { h in FeedDecoderHomepage.valid(h) }
            out.append(Candidate(id: id, source: "radio", ref: valid.absoluteString,
                                 kind: "station", title: clean(name), creator: clean(name), genres: [genre], homepage: homepage,
                                 weight: 0.5, evidence: evidence))
        }
        notes.append("radio: creator defaults to the station name; set it to the broadcaster (coverage counts broadcasters)")
        return out
    }

    // MARK: Mixcloud

    static func mixcloud(tag: String, genre: String, limit: Int, known: Set<String>,
                         notes: inout [String]) async -> [Candidate] {
        var c = URLComponents(string: "https://api.mixcloud.com/discover/")!
        c.path += slug(tag, max: 64) + "/popular/"
        c.queryItems = [.init(name: "limit", value: "\(min(limit * 3, 100))")]
        guard let url = c.url, let root = try? await getJSON(url) as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            notes.append("mixcloud: request failed")
            return []
        }
        var out: [Candidate] = []
        for m in data where out.count < limit {
            guard let key = m["key"] as? String, let name = m["name"] as? String else { continue }
            let ref = key.split(separator: "/").joined(separator: "/")
            guard let canonical = try? Canonicaliser.canonicalRef(ref, for: .mixcloud),
                  let id = StreamID.make(source: .mixcloud, ref: canonical), !known.contains(id.rawValue) else { continue }
            if (m["is_exclusive"] as? Bool) == true { continue }
            let seconds = (m["audio_length"] as? Int) ?? 0
            if seconds < CatalogLint.minMixSeconds { continue }
            let user = (m["user"] as? [String: Any])?["name"] as? String ?? ""
            out.append(Candidate(id: id.rawValue, source: "mixcloud", ref: canonical, kind: "mix", title: clean(name),
                                 creator: clean(user),
                                 genres: [genre], durationSec: seconds, weight: 1.0,
                                 evidence: ["plays": "\(m["play_count"] ?? "")", "favorites": "\(m["favorite_count"] ?? "")",
                                            "created": "\(m["created_time"] ?? "")",
                                            "todo": "probe for restrictedReason; prefer official label/artist accounts"]))
        }
        return out
    }

    // MARK: SoundCloud (scsearch via the engine)

    static func soundcloud(tag: String, genre: String, limit: Int, profile: String, known: Set<String>,
                           notes: inout [String]) async -> [Candidate] {
        let paths = Paths.profile(URL(filePath: (profile as NSString).expandingTildeInPath, directoryHint: .isDirectory))
        let layout = EngineLayout(paths: paths)
        guard let current = await EngineStore(layout: layout).current() else {
            notes.append("soundcloud skipped: no engine in \(paths.appSupport.path)")
            return []
        }
        do { try layout.createDirectories() } catch {}
        var arguments = ["--ignore-config", "--no-plugin-dirs", "--no-update", "--no-js-runtimes",
                         "--cache-dir", layout.cacheDir.path, "--socket-timeout", "10", "--flat-playlist", "-J"]
        if let proxy = SystemProxy.current().url { arguments += ["--proxy", proxy.absoluteString] }
        arguments += ["--", "scsearch\(min(limit * 2, 30)):\(tag) mix"]
        let spec = SubprocessSpec(executable: current.executableURL(in: layout), arguments: arguments,
                                  environment: layout.environment, workingDirectory: layout.tmp, timeout: .seconds(90))
        guard let result = try? await Subprocess.run(spec), result.succeeded,
              let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]] else {
            notes.append("soundcloud: scsearch failed")
            return []
        }
        var out: [Candidate] = []
        for e in entries where out.count < limit {
            let link = (e["webpage_url"] as? String) ?? (e["url"] as? String) ?? ""
            guard let pasted = try? Canonicaliser.parse(link), pasted.source == .soundcloud, let id = pasted.streamID,
                  !known.contains(id.rawValue) else { continue }
            let seconds = (e["duration"] as? Double).map { Int($0) }
            if let seconds, seconds < CatalogLint.minMixSeconds { continue }
            out.append(Candidate(id: id.rawValue, source: "soundcloud", ref: pasted.ref, kind: "mix",
                                 title: clean((e["title"] as? String) ?? ""), creator: clean((e["uploader"] as? String) ?? ""),
                                 genres: [genre], durationSec: seconds, weight: 1.0,
                                 evidence: ["todo": Self.soundCloudTodo]))
        }
        return out
    }
}

/// The feed decoder's homepage rule, for candidates.
enum FeedDecoderHomepage {
    static func valid(_ s: String) -> String? {
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              c.percentEncodedUser == nil, let host = c.percentEncodedHost, (try? RadioURLPolicy.validateHost(host)) != nil
        else { return nil }
        return c.url?.absoluteString
    }
}
