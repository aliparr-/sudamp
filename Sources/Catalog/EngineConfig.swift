// SPDX-License-Identifier: GPL-3.0-or-later

/// A yt-dlp release chosen by version and the SHA-256 of its `yt-dlp_macos.zip` (from upstream's `SHA2-256SUMS`).
public struct EnginePin: Sendable, Equatable, Codable {
    public let version: String
    public let sha256: String

    public init(version: String, sha256: String) {
        self.version = version
        self.sha256 = sha256
    }
}

/// The feed's `engine` section (DESIGN §7.1, §7.2). Everything here can end up in yt-dlp's argv, so every field is
/// validated before use and a failing value keeps its previous value (or the default) instead of being "repaired".
public struct EngineConfig: Sendable, Equatable {
    public var minAppVersion: String?
    public var pin: EnginePin?
    public var block: [String]
    /// Kill switches by platform (`youtube` also covers `youtube-live` unless that key is given explicitly).
    public var sources: [SourceKind: Bool]
    public var nightlyEscalation: Bool
    /// Fast-start order (DESIGN §7.3): earlier sources are preferred among the next few eligible picks.
    public var fastStartRank: [SourceKind]
    /// The JS ladder's `player_client` lists, tier 1 first (DESIGN §6.2).
    public var clients: [String]
    /// yt-dlp `-f` selectors by source.
    public var formats: [SourceKind: String]
    /// Extra `--extractor-args` values by source, e.g. `soundcloud:formats=hls_aac`.
    public var extractorArgs: [SourceKind: [String]]
    /// Allowed DNS suffixes for resolved media URLs (HTTPS only, checked by the Resolver).
    public var mediaHosts: [String]
    /// Items the update canary resolves (one YouTube, one SoundCloud).
    public var canary: [StreamID]

    public init(minAppVersion: String? = nil, pin: EnginePin? = nil, block: [String] = [],
                sources: [SourceKind: Bool], nightlyEscalation: Bool, fastStartRank: [SourceKind],
                clients: [String], formats: [SourceKind: String], extractorArgs: [SourceKind: [String]],
                mediaHosts: [String], canary: [StreamID]) {
        self.minAppVersion = minAppVersion
        self.pin = pin
        self.block = block
        self.sources = sources
        self.nightlyEscalation = nightlyEscalation
        self.fastStartRank = fastStartRank
        self.clients = clients
        self.formats = formats
        self.extractorArgs = extractorArgs
        self.mediaHosts = mediaHosts
        self.canary = canary
    }

    /// DESIGN §6.2 defaults, used when a field is absent or invalid in the first document seen.
    public static let defaults = EngineConfig(
        sources: [.youtube: true, .soundcloud: true, .mixcloud: true, .radio: true],
        nightlyEscalation: true,
        fastStartRank: [.radio, .soundcloud, .mixcloud, .youtube],
        clients: ["visionos", "visionos,tv_samsung"],
        formats: [
            .youtube: "bestaudio[ext=webm][format_id!*=drc]/bestaudio[format_id!*=drc]/bestaudio",
            .youtubeLive: "bestaudio[protocol^=m3u8]/worst[protocol^=m3u8]",
            .soundcloud: "hls_aac_160k/hls_aac_96k/bestaudio",
            .mixcloud: "hls-192/http/bestaudio",
        ],
        extractorArgs: [.soundcloud: ["soundcloud:formats=hls_aac"]],
        mediaHosts: ["googlevideo.com", "media-streaming.soundcloud.cloud", "mixcloud.stream"],
        canary: []
    )

    /// Whether a source's kill switch is on. `youtube-live` follows `youtube` unless it has its own key.
    public func isSourceEnabled(_ source: SourceKind) -> Bool {
        sources[source] ?? sources[source.platform] ?? true
    }

    /// The `-f` selector for a source (`youtube-live` has its own; nothing for radio).
    public func format(for source: SourceKind) -> String? { formats[source] }

    /// Position in `fastStartRank`; unlisted sources rank after listed ones, `youtube-live` with `youtube`.
    public func fastStartPosition(of source: SourceKind) -> Int {
        fastStartRank.firstIndex(of: source) ?? fastStartRank.firstIndex(of: source.platform) ?? fastStartRank.count
    }
}

/// One rejected engine value: the field kept its previous value.
public struct EngineIssue: Sendable, Equatable, CustomStringConvertible {
    public let field: String
    public let reason: String
    public var description: String { "engine.\(field): \(reason)" }
}

/// The strict string rules of DESIGN §7.2.
public enum EngineValidation {
    /// `^[a-z_]+(,[a-z_]+)*$`
    public static func isValidClientList(_ s: String) -> Bool {
        s.count <= 128 && s.wholeMatch(of: #/[a-z_]+(,[a-z_]+)*/#) != nil
    }

    /// Only `[A-Za-z0-9_\-\[\]\^\*!=/,.<>?:+]`, not starting with `-` (it would become a yt-dlp option).
    public static func isValidFormat(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 256 && !s.hasPrefix("-")
            && s.wholeMatch(of: #/[A-Za-z0-9_\-\[\]\^\*!=\/,.<>?:+]+/#) != nil
    }

    /// `^[a-z]+:[a-z_]+=[a-z0-9_,]+$`
    public static func isValidExtractorArg(_ s: String) -> Bool {
        s.count <= 256 && s.wholeMatch(of: #/[a-z]+:[a-z_]+=[a-z0-9_,]+/#) != nil
    }

    /// A lower-case DNS suffix with at least two labels.
    public static func isValidMediaHost(_ s: String) -> Bool {
        s.count <= 253 && s.wholeMatch(of: #/[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+/#) != nil
    }

    /// `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$` (yt-dlp's date versions).
    public static func isValidEngineVersion(_ s: String) -> Bool {
        s.wholeMatch(of: #/[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?/#) != nil
    }

    /// 64 lower-case hex digits.
    public static func isValidSHA256(_ s: String) -> Bool { s.wholeMatch(of: #/[0-9a-f]{64}/#) != nil }

    /// `major.minor.patch`.
    public static func isValidAppVersion(_ s: String) -> Bool { s.wholeMatch(of: #/[0-9]{1,6}(\.[0-9]{1,6}){2}/#) != nil }
}

extension EngineConfig {
    /// Decodes the `engine` object over `previous`: absent fields keep `previous`, invalid ones keep it too and are
    /// reported. List fields are all-or-nothing (half a JS ladder is worse than the old one); map fields per key.
    public static func decode(_ json: JSONValue?, previous: EngineConfig = .defaults) -> (EngineConfig, [EngineIssue]) {
        var config = previous
        var issues: [EngineIssue] = []
        guard let json else { return (config, issues) }
        guard let o = json.objectValue else {
            return (config, [EngineIssue(field: "", reason: "not an object")])
        }
        func reject(_ field: String, _ reason: String) { issues.append(EngineIssue(field: field, reason: reason)) }

        if let v = o["minAppVersion"] {
            if v.isNull { config.minAppVersion = nil }
            else if let s = v.stringValue, EngineValidation.isValidAppVersion(s) { config.minAppVersion = s }
            else { reject("minAppVersion", "not major.minor.patch") }
        }
        if let v = o["pin"] {
            if v.isNull { config.pin = nil }
            else if let ver = v["version"]?.stringValue, EngineValidation.isValidEngineVersion(ver),
                    let sha = v["sha256"]?.stringValue, EngineValidation.isValidSHA256(sha) {
                config.pin = EnginePin(version: ver, sha256: sha)
            } else { reject("pin", "needs a YYYY.MM.DD version and a lower-case hex sha256") }
        }
        if let v = o["block"] {
            if let list = strings(v), list.allSatisfy(EngineValidation.isValidEngineVersion) { config.block = list }
            else { reject("block", "every entry must be a YYYY.MM.DD version") }
        }
        if let v = o["sources"] {
            if let map = v.objectValue {
                for (key, value) in map {
                    guard let kind = SourceKind(rawValue: key) else { reject("sources.\(key)", "unknown source"); continue }
                    guard let on = value.boolValue else { reject("sources.\(key)", "not a boolean"); continue }
                    config.sources[kind] = on
                }
            } else { reject("sources", "not an object") }
        }
        if let v = o["nightlyEscalation"] {
            if let b = v.boolValue { config.nightlyEscalation = b } else { reject("nightlyEscalation", "not a boolean") }
        }
        if let v = o["fastStartRank"] {
            if let list = strings(v), !list.isEmpty, Set(list).count == list.count {
                let kinds = list.compactMap(SourceKind.init(rawValue:))
                if kinds.count == list.count { config.fastStartRank = kinds }
                else { reject("fastStartRank", "unknown source") }
            } else { reject("fastStartRank", "must be a non-empty list of distinct sources") }
        }
        if let v = o["clients"] {
            if let list = strings(v), !list.isEmpty, list.count <= 8, list.allSatisfy(EngineValidation.isValidClientList) {
                config.clients = list
            } else { reject("clients", "every entry must match ^[a-z_]+(,[a-z_]+)*$") }
        }
        if let v = o["formats"] {
            if let map = v.objectValue {
                for (key, value) in map {
                    guard let kind = SourceKind(rawValue: key), kind != .radio else {
                        reject("formats.\(key)", "unknown source"); continue
                    }
                    guard let s = value.stringValue, EngineValidation.isValidFormat(s) else {
                        reject("formats.\(key)", "invalid format selector"); continue
                    }
                    config.formats[kind] = s
                }
            } else { reject("formats", "not an object") }
        }
        if let v = o["extractorArgs"] {
            if let map = v.objectValue {
                for (key, value) in map {
                    guard let kind = SourceKind(rawValue: key), kind != .radio else {
                        reject("extractorArgs.\(key)", "unknown source"); continue
                    }
                    let list = value.stringValue.map { [$0] } ?? strings(value)
                    guard let list, list.count <= 8, list.allSatisfy(EngineValidation.isValidExtractorArg) else {
                        reject("extractorArgs.\(key)", "every entry must match ^[a-z]+:[a-z_]+=[a-z0-9_,]+$"); continue
                    }
                    config.extractorArgs[kind] = list
                }
            } else { reject("extractorArgs", "not an object") }
        }
        if let v = o["mediaHosts"] {
            if let list = strings(v), !list.isEmpty, list.allSatisfy(EngineValidation.isValidMediaHost) {
                config.mediaHosts = list
            } else { reject("mediaHosts", "every entry must be a lower-case DNS suffix") }
        }
        if let v = o["canary"] {
            if let list = strings(v) {
                let ids = list.compactMap(StreamID.init(rawValue:))
                if ids.count == list.count, ids.allSatisfy({ $0.source != .radio }) { config.canary = ids }
                else { reject("canary", "every entry must be a non-radio stream id") }
            } else { reject("canary", "not a list of strings") }
        }
        return (config, issues)
    }

    private static func strings(_ v: JSONValue) -> [String]? {
        guard let a = v.arrayValue else { return nil }
        let s = a.compactMap(\.stringValue)
        return s.count == a.count ? s : nil
    }
}
