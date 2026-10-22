// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation

/// A yt-dlp release tag: `YYYY.MM.DD` (stable) or `YYYY.MM.DD.N` (nightly builds and hotfixes).
public struct EngineVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let string: String
    private let parts: [Int]

    /// Accepts only `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$` (DESIGN §7.2).
    public init?(_ string: String) {
        let fields = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (3...4).contains(fields.count),
              fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }),
              fields.allSatisfy({ $0.count <= 18 }) else { return nil }
        self.string = string
        parts = fields.map { Int($0)! }
    }

    public var description: String { string }

    public static func < (a: EngineVersion, b: EngineVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

/// The engine part of the feed that EngineStore honours (DESIGN §6.1, §7.1): an optional `pin` for the first
/// install and a `block` list that is always honoured.
public struct EngineInstallPolicy: Sendable, Equatable, Codable {
    public struct Pin: Sendable, Equatable, Codable {
        public var version: String
        /// SHA-256 of `yt-dlp_macos.zip`, copied from upstream's `SHA2-256SUMS`.
        public var sha256: String

        public init(version: String, sha256: String) {
            self.version = version
            self.sha256 = sha256
        }
    }

    public var pin: Pin?
    public var block: [String]

    public init(pin: Pin? = nil, block: [String] = []) {
        self.pin = pin
        self.block = block
    }

    /// The install policy from the feed's (already validated) engine section.
    public init(feed: Catalog.EngineConfig) {
        self.init(pin: feed.pin.map { Pin(version: $0.version, sha256: $0.sha256) }, block: feed.block)
    }

    /// Drops values that fail DESIGN §7.2's rules (a bad pin is ignored; bad block entries are skipped) and
    /// describes what was dropped, so callers can log it.
    public func validated() -> (config: EngineInstallPolicy, rejected: [String]) {
        var rejected: [String] = []
        var pin = self.pin
        if let p = pin, EngineVersion(p.version) == nil || !FileDigest.isSHA256Hex(p.sha256) {
            rejected.append("pin \(p.version)")
            pin = nil
        }
        let block = self.block.filter { v in
            if EngineVersion(v) != nil { return true }
            rejected.append("block \(v)")
            return false
        }
        return (EngineInstallPolicy(pin: pin, block: block), rejected)
    }

    public func isBlocked(_ version: String) -> Bool { block.contains(version) }
}

/// Which release to install and why.
public struct EngineChoice: Sendable, Equatable, Codable {
    public enum Reason: String, Sendable, Codable {
        /// The feed's pin (not blocked, not above an `_update_spec` lock).
        case pin
        /// Upstream's latest release (`releases/latest`).
        case latest
        /// Latest was blocked, so the newest non-blocked release from the release feed.
        case newestNonBlocked
        /// An `_update_spec` lock line caps this machine at an older release, as yt-dlp's own updater would.
        case updateSpecLock
    }

    public var version: String
    public var reason: Reason
    /// The pin's SHA-256 when `reason == .pin`; otherwise the upstream `SHA2-256SUMS` entry is authoritative.
    public var expectedSHA256: String?

    public init(version: String, reason: Reason, expectedSHA256: String? = nil) {
        self.version = version
        self.reason = reason
        self.expectedSHA256 = expectedSHA256
    }
}

/// The pure version-choice rule, separate from networking so it is unit-tested (PLAN M1: a feed whose `block`
/// lists the newest release makes a first install pick `pin`).
public enum EngineChooser {
    /// - Parameters:
    ///   - latest: upstream `releases/latest`, if fetched.
    ///   - recent: other known releases (any order), e.g. from `releases.atom`.
    ///   - lockedTag: the cap from `_update_spec` for this machine, if a lock line matched.
    public static func choose(config: EngineInstallPolicy, latest: String?, recent: [String] = [],
                              lockedTag: String? = nil) -> EngineChoice? {
        let config = config.validated().config
        let cap = lockedTag.flatMap(EngineVersion.init)
        func allowed(_ s: String) -> EngineVersion? {
            guard let v = EngineVersion(s), !config.isBlocked(s) else { return nil }
            if let cap, v > cap { return nil }
            return v
        }
        if let pin = config.pin, allowed(pin.version) != nil {
            return EngineChoice(version: pin.version, reason: .pin, expectedSHA256: pin.sha256)
        }
        let pool = ([latest, lockedTag].compactMap { $0 } + recent).compactMap(allowed)
        guard let best = Set(pool).max() else { return nil }
        if best.string == latest { return EngineChoice(version: best.string, reason: .latest) }
        if best.string == lockedTag, let latest, let l = EngineVersion(latest), let cap, l > cap {
            return EngineChoice(version: best.string, reason: .updateSpecLock)
        }
        return EngineChoice(version: best.string, reason: .newestNonBlocked)
    }
}

/// Upstream `SHA2-256SUMS`: `<64 hex>  <file name>` per line (`shasum -a 256` format, optional `*` binary mark).
public struct SHA256Sums: Sendable, Equatable {
    public let entries: [String: String]

    public init(parsing text: String) {
        var entries: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let hash = fields[0].lowercased()
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if FileDigest.isSHA256Hex(hash) { entries[name] = hash }
        }
        self.entries = entries
    }

    public subscript(file: String) -> String? { entries[file] }
}
