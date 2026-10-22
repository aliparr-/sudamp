// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One problem `catalog-tool lint` found.
public struct LintIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Rule: String, Sendable, CaseIterable {
        /// A file is not strict JSON (syntax, duplicate keys) or not the expected shape.
        case json
        /// Unknown keys, wrong types, invalid envelope values, items the feed decoder would drop.
        case schema
        /// A ref or ID that isn't in DESIGN §7.1's canonical form.
        case canonical
        /// The same genre, stream ID or radio URL twice.
        case duplicate
        /// A radio URL the policy refuses (DESIGN §7.1).
        case radioURL
        /// A genre below the 1.0 rule (`CoverageRule.release`).
        case coverage
        /// An engine value failing DESIGN §7.2's strict rules, or a pin without a checksum.
        case engine
        /// The update canary's items (one YouTube VOD, one SoundCloud) missing or not in the catalog.
        case canary
        /// `expiresAt` missing, in the past, before `generatedAt` or close.
        case expiry
        /// Curation policy (DESIGN §7.3): no SomaFM without permission, HTTPS radio, long mixes.
        case policy
        /// `catalog/feed.json` differs from a fresh build.
        case stale
    }

    public enum Severity: String, Sendable { case error, warning }

    public let rule: Rule
    public let severity: Severity
    public let location: String
    public let message: String

    public init(_ rule: Rule, _ location: String, _ message: String, severity: Severity = .error) {
        self.rule = rule
        self.severity = severity
        self.location = location
        self.message = message
    }

    public var description: String { "\(severity.rawValue): \(location): [\(rule.rawValue)] \(message)" }
}

/// `catalog-tool lint` (PLAN M7): the source files' shape, then everything about the built document: the feed
/// decoder (which must drop nothing), DESIGN §7.1's canonicaliser and radio URL policy, duplicates, DESIGN §7.2's
/// engine strings, the 1.0 coverage rule, the canary, expiry and curation policy; and that `feed.json` is current.
public enum CatalogLint {
    /// Mixes shorter than this are flagged (the catalog's convention is ≥ 50 minutes).
    public static let minMixSeconds = 40 * 60
    /// A published document should stay valid at least this long.
    public static let expiryWarning: TimeInterval = 60 * 86_400

    /// Lints `catalog/`'s sources and, when given, the committed `feed.json` against a fresh build.
    public static func lint(source: CatalogSource, existingFeed: Data?, rule: CoverageRule = .release,
                            now: Date = Date()) -> [LintIssue] {
        var issues = lintSourceFiles(source)
        let built: Data
        do {
            built = try CatalogBuilder.build(source)
        } catch .missingPin(let v) {
            return issues + [LintIssue(.engine, CatalogSource.pinsFile, "no SHA-256 for pinned yt-dlp \(v); run `catalog-tool build`")]
        } catch {
            return issues + [LintIssue(.json, "build", error.description)]
        }
        issues += lint(feed: built, location: "\(CatalogSource.feedFile) (built)", rule: rule, now: now)
        if let existingFeed, existingFeed != built {
            issues.append(LintIssue(.stale, CatalogSource.feedFile, "differs from a fresh build; run `catalog-tool build`"))
        }
        return issues
    }

    /// Lints one feed document (a built or published `feed.json`).
    public static func lint(feed data: Data, location: String, rule: CoverageRule = .release,
                            now: Date = Date()) -> [LintIssue] {
        var issues: [LintIssue] = []
        func add(_ r: LintIssue.Rule, _ s: LintIssue.Severity = .error, at place: String? = nil, m: String) {
            issues.append(LintIssue(r, place ?? location, m, severity: s))
        }
        let ordered: OrderedJSON
        do { ordered = try OrderedJSON.parse(data) } catch { return [LintIssue(.json, location, error.description)] }
        let result: FeedDecodeResult
        do { result = try FeedDecoder.decode(ordered.jsonValue) } catch {
            return [LintIssue(.schema, location, error.description)]
        }
        let doc = result.document
        let rawStreams = ordered["catalog"]?["streams"]?.elements ?? []

        for m in ordered.keys where !(CatalogLayout.releaseKeys + ["catalog", "engine"]).contains(m) {
            add(.schema, m: "unknown top-level key \"\(m)\"")
        }
        for k in ordered["engine"]?.keys ?? [] where !CatalogLayout.engineKeys.contains(k) {
            add(.schema, m: "unknown engine key \"\(k)\"")
        }
        for d in result.dropped {
            let item = d.index >= 0 && d.section == .stream && d.index < rawStreams.count ? rawStreams[d.index] : nil
            add(classify(d, item: item), at: "\(location) \(d.section.rawValue)s[\(d.index)]", m: "\(d.id ?? "?"): \(d.reason)")
        }
        for issue in result.engineIssues { add(.engine, m: issue.description) }

        // Per stream: unknown keys, non-canonical spelling, unknown extra genres, policy.
        let known = Set(doc.catalog.genres.map(\.id.rawValue))
        var radioURLs: [String: String] = [:]
        for (i, raw) in rawStreams.enumerated() {
            let id = raw["id"]?.stringValue ?? "streams[\(i)]"
            for k in raw.keys where !CatalogLayout.streamKeys.contains(k) { add(.schema, m: "\(id): unknown key \"\(k)\"") }
            for g in raw["genres"]?.elements?.compactMap(\.stringValue) ?? [] where !known.contains(g) {
                add(.schema, .warning, m: "\(id): unknown genre \"\(g)\" ignored")
            }
            guard let sid = StreamID(rawValue: id), let s = doc.catalog[sid], let rawRef = raw["ref"]?.stringValue else { continue }
            if rawRef != s.ref { add(.canonical, m: "\(id): write the ref as \(s.ref)") }
            if s.isRadio {
                if let other = radioURLs[s.ref] { add(.duplicate, m: "\(id): same stream URL as \(other)") }
                radioURLs[s.ref] = id
                let host = s.url.host?.lowercased() ?? ""
                if host == "somafm.com" || host.hasSuffix(".somafm.com") {
                    add(.policy, m: "\(id): SomaFM stations need SomaFM's permission first (DESIGN §7.3)")
                }
                if s.url.scheme != "https" { add(.policy, .warning, m: "\(id): prefer an HTTPS stream") }
            } else if s.kind == .mix {
                if let d = s.durationSec, d < minMixSeconds {
                    add(.policy, .warning, m: "\(id): \(d / 60) min is short for a mix (≥ \(minMixSeconds / 60))")
                }
                if s.durationSec == nil { add(.policy, .warning, m: "\(id): mix without durationSec") }
            }
        }

        for v in CoverageValidator.check(doc.catalog, engine: doc.engine, rule: rule) { add(.coverage, m: v.description) }
        for c in CoverageValidator.lint(doc) {
            add(c.hasPrefix("genre ") ? .coverage : .canary, m: c)
        }
        if doc.engine.pin == nil { add(.engine, .warning, m: "no engine.pin: first installs take upstream's latest") }

        // Expiry: fetched documents expire (DESIGN §7.2), so a published one must say when.
        if let e = doc.expiresAt {
            if e <= doc.generatedAt { add(.expiry, m: "expiresAt is not after generatedAt") }
            if e <= now { add(.expiry, m: "expired at \(e.formatted(.iso8601))") }
            else if e.timeIntervalSince(now) < expiryWarning {
                add(.expiry, .warning, m: "expires within \(Int(expiryWarning / 86_400)) days (\(e.formatted(.iso8601)))")
            }
        } else {
            add(.expiry, m: "missing expiresAt (an unexpiring signed document could be replayed forever)")
        }
        return issues
    }

    // MARK: Source files

    static func lintSourceFiles(_ source: CatalogSource) -> [LintIssue] {
        var issues: [LintIssue] = []
        func add(_ r: LintIssue.Rule, _ file: String, _ m: String) { issues.append(LintIssue(r, file, m)) }
        func warn(_ r: LintIssue.Rule, _ file: String, _ m: String) { issues.append(LintIssue(r, file, m, severity: .warning)) }
        // release.json
        let release = source.release
        if release.json.members == nil { add(.json, release.name, "not an object") }
        for k in release.json.keys where !CatalogLayout.releaseKeys.contains(k) { add(.schema, release.name, "unknown key \"\(k)\"") }
        if release.json["schema"]?.intLiteral != FeedDocument.supportedSchema {
            add(.schema, release.name, "schema must be \(FeedDocument.supportedSchema)")
        }
        if (release.json["revision"]?.intLiteral ?? -1) < 0 { add(.schema, release.name, "revision must be an integer ≥ 0") }
        for k in ["generatedAt", "expiresAt"] where release.json[k] != nil
            && release.json[k]?.stringValue.flatMap(FeedDecoder.parseDate) == nil {
            add(.schema, release.name, "\(k) must be an ISO 8601 date")
        }
        // engine.json
        let engine = source.engine
        if engine.json.members == nil { add(.json, engine.name, "not an object") }
        for k in engine.json.keys where !CatalogLayout.engineKeys.contains(k) { add(.schema, engine.name, "unknown key \"\(k)\"") }
        if let pin = engine.json["pin"], pin != .null {
            if pin["version"]?.stringValue.map(EngineValidation.isValidEngineVersion) != true {
                add(.engine, engine.name, "pin.version must be a YYYY.MM.DD yt-dlp version")
            }
            for k in pin.keys where k != "version" && k != "sha256" { add(.schema, engine.name, "unknown pin key \"\(k)\"") }
        }
        // genres/*.json
        var genreFiles: [String: String] = [:]
        var streamFiles: [String: String] = [:]
        for file in source.genres {
            let j = file.json
            guard j.members != nil else { add(.json, file.name, "not an object"); continue }
            for k in j.keys where !CatalogLayout.genreFileKeys.contains(k) { add(.schema, file.name, "unknown key \"\(k)\"") }
            guard let id = j["id"]?.stringValue, GenreID(rawValue: id) != nil else {
                add(.schema, file.name, "id must be lower-case words joined by hyphens"); continue
            }
            if let other = genreFiles[id] { add(.duplicate, file.name, "genre \(id) is also defined in \(other)") }
            genreFiles[id] = file.name
            if file.name != "\(CatalogSource.genresDirectory)/\(id).json" {
                warn(.schema, file.name, "name the file \(CatalogSource.genresDirectory)/\(id).json")
            }
            if j["name"]?.stringValue.flatMap(FeedDecoder.cleanText) == nil { add(.schema, file.name, "missing name") }
            if j["order"] != nil, j["order"]?.intLiteral == nil { add(.schema, file.name, "order must be an integer") }
            guard let streams = (j["streams"] ?? .array([])).elements else {
                add(.schema, file.name, "streams must be a list"); continue
            }
            for (i, s) in streams.enumerated() {
                guard s.members != nil else { add(.schema, file.name, "streams[\(i)] is not an object"); continue }
                let sid = streamID(s) ?? "streams[\(i)]"
                // The build writes known keys only, so a typo (`durationSecs`) would vanish silently.
                for k in s.keys where !CatalogLayout.streamKeys.contains(k) {
                    add(.schema, file.name, "\(sid): unknown key \"\(k)\"")
                }
                if let g = s["genres"] {
                    let names = g.elements?.compactMap(\.stringValue)
                    if names?.contains(id) != true { add(.schema, file.name, "\(sid): \"genres\" must include \(id)") }
                }
                if let other = streamFiles[sid] { add(.duplicate, file.name, "\(sid) is also listed in \(other)") }
                streamFiles[sid] = file.name
            }
        }
        if source.genres.isEmpty { add(.schema, CatalogSource.genresDirectory, "no genre files") }
        return issues
    }

    /// The ID a raw stream has (radio: its `id`) or would derive from its ref.
    static func streamID(_ s: OrderedJSON) -> String? {
        if let id = s["id"]?.stringValue { return id }
        guard let source = s["source"]?.stringValue.flatMap(SourceKind.init(rawValue:)), let ref = s["ref"]?.stringValue else {
            return nil
        }
        return StreamID.make(source: source, ref: ref)?.rawValue
    }

    /// Which rule a dropped item broke.
    static func classify(_ d: DroppedItem, item: OrderedJSON?) -> LintIssue.Rule {
        if d.reason == "duplicate id" { return .duplicate }
        guard d.section == .stream, let item else { return .schema }
        if item["source"]?.stringValue == SourceKind.radio.rawValue, let ref = item["ref"]?.stringValue,
           (try? RadioURLPolicy.validate(ref)) == nil {
            return .radioURL
        }
        if d.reason.contains(" ref ") || d.reason.hasPrefix("id does not match") || d.reason.hasPrefix("invalid ref")
            || d.reason.hasPrefix("radio needs an id") {
            return .canonical
        }
        return .schema
    }
}
