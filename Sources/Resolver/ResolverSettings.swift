// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// One stream to resolve. The URL should already be canonical (Catalog rebuilds it from the ref, DESIGN §7.1);
/// Resolver still refuses non-HTTPS URLs and hosts that don't belong to the source.
public struct ResolveRequest: Sendable, Hashable, Codable {
    public var source: SourceKind
    public var url: URL

    public init(source: SourceKind, url: URL) {
        self.source = source
        self.url = url
    }

    /// Page hosts accepted per source (the canonical one first).
    public static func pageHosts(for source: SourceKind) -> [String] {
        switch source {
        case .youtube, .youtubeLive: ["www.youtube.com", "youtube.com", "m.youtube.com", "music.youtube.com"]
        case .soundcloud: ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"]
        case .mixcloud: ["www.mixcloud.com", "mixcloud.com", "m.mixcloud.com"]
        case .radio: []
        }
    }
}

/// The JS ladder (DESIGN §6.2): tier 1 runs no JS runtime; tier 2 adds bundled QuickJS-NG and more clients.
public enum ResolveTier: Int, Sendable, Codable, CaseIterable, Comparable {
    case jsless = 1
    case quickjs = 2

    public static func < (a: ResolveTier, b: ResolveTier) -> Bool { a.rawValue < b.rawValue }
}

/// User picks pre-empt prefetch and hover resolves (DESIGN §6.3 concurrency).
public enum ResolvePriority: Int, Sendable, Codable, Comparable {
    case background = 0
    case user = 1

    public static func < (a: ResolvePriority, b: ResolvePriority) -> Bool { a.rawValue < b.rawValue }
}

/// Feed-overridable engine strings (DESIGN §6.2 table, §7.1 `engine`), validated before they reach argv
/// (§7.2): a failing value keeps the default.
public struct ResolverSettings: Sendable, Equatable {
    /// YouTube `player_client` list per tier: index 0 is tier 1, index 1 is tier 2 (feed `engine.clients`).
    public var clients: [String]
    /// `-f` per source (feed `engine.formats`).
    public var formats: [SourceKind: String]
    /// `--extractor-args` values per source (feed `engine.extractorArgs`), besides the YouTube client list.
    public var extractorArgs: [SourceKind: [String]]
    /// Media URLs must be HTTPS on one of these DNS suffixes (feed `engine.mediaHosts`; captured in R1).
    public var mediaHosts: [SourceKind: [String]]
    /// yt-dlp `--socket-timeout`, seconds.
    public var socketTimeout: Int
    /// Process-group kill deadline per tier.
    public var tier1Timeout: Duration
    public var tier2Timeout: Duration

    public init(clients: [String] = Self.defaultClients, formats: [SourceKind: String] = Self.defaultFormats,
                extractorArgs: [SourceKind: [String]] = Self.defaultExtractorArgs,
                mediaHosts: [SourceKind: [String]] = Self.defaultMediaHosts, socketTimeout: Int = 10,
                tier1Timeout: Duration = .seconds(10), tier2Timeout: Duration = .seconds(12)) {
        self.clients = clients
        self.formats = formats
        self.extractorArgs = extractorArgs
        self.mediaHosts = mediaHosts
        self.socketTimeout = socketTimeout
        self.tier1Timeout = tier1Timeout
        self.tier2Timeout = tier2Timeout
    }

    public static let standard = ResolverSettings()

    public static let defaultClients = ["visionos", "visionos,tv_samsung"]

    public static let defaultFormats: [SourceKind: String] = [
        .youtube: "bestaudio[ext=webm][format_id!*=drc]/bestaudio[format_id!*=drc]/bestaudio",
        .youtubeLive: "bestaudio[protocol^=m3u8]/worst[protocol^=m3u8]",
        .soundcloud: "hls_aac_160k/hls_aac_96k/bestaudio",
        .mixcloud: "hls-192/http/bestaudio",
    ]

    public static let defaultExtractorArgs: [SourceKind: [String]] = [
        // One api-v2 request per transcoding otherwise (http_aac, hls_aac, http_opus, …), with 429 risk.
        .soundcloud: ["soundcloud:formats=hls_aac"],
    ]

    /// Exactly the suffixes observed in R1 (docs/spikes/R1.md), for media URLs and their HLS segments alike:
    /// YouTube VOD `rr*---sn-*.googlevideo.com`, `/live` `manifest.googlevideo.com`; SoundCloud
    /// `playback.media-streaming.soundcloud.cloud`; Mixcloud `dl.mixcloud.stream` (progressive) and
    /// `aod.mixcloud.stream` (HLS/DASH). A CDN move fails as engine/`mediaHost` until the feed lists the new one.
    public static let defaultMediaHosts: [SourceKind: [String]] = [
        .youtube: ["googlevideo.com"],
        .youtubeLive: ["googlevideo.com"],
        .soundcloud: ["media-streaming.soundcloud.cloud"],
        .mixcloud: ["mixcloud.stream"],
    ]

    public func timeout(for tier: ResolveTier) -> Duration { tier == .jsless ? tier1Timeout : tier2Timeout }

    /// The `player_client` list for a tier, or nil if the feed supplied none for it.
    public func clientList(for tier: ResolveTier) -> String? {
        let i = tier.rawValue - 1
        return i < clients.count ? clients[i] : nil
    }

    /// Replaces every value failing DESIGN §7.2's rules with its default, and lists what was replaced.
    public func validated() -> (settings: ResolverSettings, rejected: [String]) {
        var s = self
        var rejected: [String] = []
        if !clients.allSatisfy(EngineStrings.isClientList) || clients.isEmpty {
            rejected.append("clients \(clients)")
            s.clients = Self.defaultClients
        }
        for (k, v) in formats where !EngineStrings.isFormat(v) {
            rejected.append("format[\(k.rawValue)] \(v)")
            s.formats[k] = Self.defaultFormats[k]
        }
        for (k, v) in extractorArgs where !v.allSatisfy(EngineStrings.isExtractorArg) {
            rejected.append("extractorArgs[\(k.rawValue)] \(v)")
            s.extractorArgs[k] = Self.defaultExtractorArgs[k]
        }
        for (k, v) in mediaHosts where v.isEmpty || !v.allSatisfy(EngineStrings.isHostSuffix) {
            rejected.append("mediaHosts[\(k.rawValue)] \(v)")
            s.mediaHosts[k] = Self.defaultMediaHosts[k]
        }
        if !(1...60).contains(socketTimeout) {
            rejected.append("socketTimeout \(socketTimeout)")
            s.socketTimeout = 10
        }
        return (s, rejected)
    }
}

/// DESIGN §7.2 strict validation of feed strings that reach yt-dlp's argv.
public enum EngineStrings {
    /// `^[a-z_]+(,[a-z_]+)*$`
    public static func isClientList(_ s: String) -> Bool {
        let items = s.split(separator: ",", omittingEmptySubsequences: false)
        return !items.isEmpty && items.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { isLower($0) || $0 == 0x5F } }
    }

    /// Only `[A-Za-z0-9_\-\[\]\^\*!=/,.<>?:+]`, not starting with `-`.
    public static func isFormat(_ s: String) -> Bool {
        let extra = Set("_-[]^*!=/,.<>?:+".utf8)
        return !s.isEmpty && !s.hasPrefix("-") && s.utf8.allSatisfy { isAlnum($0) || extra.contains($0) }
    }

    /// `^[a-z]+:[a-z_]+=[a-z0-9_,]+$`
    public static func isExtractorArg(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard let colon = u.firstIndex(of: 0x3A), let eq = u.firstIndex(of: 0x3D), colon < eq else { return false }
        let ie = u[..<colon], key = u[(colon + 1)..<eq], value = u[(eq + 1)...]
        return !ie.isEmpty && ie.allSatisfy(isLower)
            && !key.isEmpty && key.allSatisfy { isLower($0) || $0 == 0x5F }
            && !value.isEmpty && value.allSatisfy { isLower($0) || isDigit($0) || $0 == 0x5F || $0 == 0x2C }
    }

    /// A lower-case DNS suffix with at least two labels, e.g. `googlevideo.com`.
    public static func isHostSuffix(_ s: String) -> Bool {
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && s.utf8.count <= 253 && labels.allSatisfy { l in
            let b = Array(l.utf8)
            return (1...63).contains(b.count) && b.first != 0x2D && b.last != 0x2D
                && b.allSatisfy { isLower($0) || isDigit($0) || $0 == 0x2D }
        }
    }

    private static func isLower(_ c: UInt8) -> Bool { (0x61...0x7A).contains(c) }
    private static func isDigit(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) }
    private static func isAlnum(_ c: UInt8) -> Bool { isLower(c) || isDigit(c) || (0x41...0x5A).contains(c) }
}
