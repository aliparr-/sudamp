// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// A non-bundled candidate for the active document (a cached or freshly fetched copy).
public struct FeedCandidate: Sendable {
    public let feed: LoadedFeed
    /// Ed25519 signature checked against a trusted key. Unverified candidates are never chosen.
    public let signatureVerified: Bool

    public init(feed: LoadedFeed, signatureVerified: Bool) {
        self.feed = feed
        self.signatureVerified = signatureVerified
    }
}

/// Why a fetched or cached document was not used (`feed.rejected`'s `reason`).
public enum FeedRejection: Error, Sendable, Equatable, CustomStringConvertible {
    /// No trusted key verifies `feed.json.sig` over the body (a tampered byte, the wrong key, a missing signature).
    case signature
    /// The envelope failed (not JSON, unknown major schema, a missing or malformed envelope field).
    case invalid(String)
    /// `revision` is below the cached copy's (anti-rollback).
    case rollback(revision: Int, minimum: Int)
    /// A fetched document past its `expiresAt` (bundled documents never expire).
    case expired(Date)
    /// `engine.minAppVersion` is above this app's version.
    case minAppVersion(String)
    /// Not newer than the document already in use (the bundled copy wins ties).
    case notNewer(revision: Int, active: Int)

    /// The short reason recorded in `metrics.jsonl`.
    public var reason: String {
        switch self {
        case .signature: "signature"
        case .invalid: "invalid"
        case .rollback: "rollback"
        case .expired: "expired"
        case .minAppVersion: "minAppVersion"
        case .notNewer: "notNewer"
        }
    }

    public var description: String {
        switch self {
        case .signature: "signature does not verify against a trusted key"
        case .invalid(let d): "invalid document: \(d)"
        case .rollback(let r, let m): "revision \(r) is below the cached revision \(m)"
        case .expired(let d): "expired at \(d.formatted(.iso8601))"
        case .minAppVersion(let v): "needs app version \(v)"
        case .notNewer(let r, let a): "revision \(r) is not newer than the active revision \(a)"
        }
    }
}

/// Chooses the active document (DESIGN §7.2):
/// - the bundled snapshot is always valid: it never expires and has no anti-rollback;
/// - a cached or fetched document must verify, be unexpired (`expiresAt` applies to them only), allow this app
///   version (`minAppVersion`) and, for anti-rollback, have a revision at least `minimumRevision` (the cached one's);
/// - the highest valid revision wins, ties going to the bundled copy (then to the earlier candidate).
public enum ActiveFeedSelector {
    public static func select(bundled: LoadedFeed, candidates: [FeedCandidate], appVersion: String, now: Date,
                              minimumRevision: Int? = nil) -> LoadedFeed {
        var best = bundled
        for c in candidates
        where rejection(of: c, appVersion: appVersion, now: now, minimumRevision: minimumRevision) == nil
            && c.feed.document.revision > best.document.revision {
            best = c.feed
        }
        return best
    }

    /// Why `candidate` can't be used at all (nil: it is valid, whatever its revision).
    public static func rejection(of candidate: FeedCandidate, appVersion: String, now: Date,
                                 minimumRevision: Int? = nil) -> FeedRejection? {
        let d = candidate.feed.document
        guard candidate.signatureVerified, candidate.feed.origin != .bundled else { return .signature }
        if let minimumRevision, d.revision < minimumRevision {
            return .rollback(revision: d.revision, minimum: minimumRevision)
        }
        if let expires = d.expiresAt, expires <= now { return .expired(expires) }
        if let min = d.engine.minAppVersion, AppVersion.compare(appVersion, min) == .orderedAscending {
            return .minAppVersion(min)
        }
        return nil
    }
}

/// Numeric `major.minor.patch` comparison; a pre-release suffix (`0.1.0-dev`) compares by its numeric part.
public enum AppVersion {
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = components(a), y = components(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func components(_ s: String) -> [Int] {
        let numeric = s.prefix { $0.isNumber || $0 == "." }
        return numeric.split(separator: ".").map { Int($0) ?? 0 }
    }
}
