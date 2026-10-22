// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The Ed25519 keys this build accepts `feed.json` signatures from (DESIGN §7.2: two embedded keys, for rotation).
///
/// - **Production keys** (`productionKeys`): base64 raw public keys, at most two (current and next). Empty until the
///   owner generates and holds the production key (before M8). With no production key a release build trusts
///   nothing, so it never fetches and plays its bundled snapshot only.
/// - **The test key** (`testKey`, `Fixtures/keys/test-ed25519.pub`): its private half is committed, so it is
///   compiled in only under `#if DEBUG`. Release builds never trust it.
public struct FeedTrust: Sendable, Equatable {
    /// Production feed-signing public keys (`catalog-tool keygen` prints the line to paste here). At most two.
    public static let productionKeys: [String] = []

    /// The committed test key (debug builds only).
    public static let testKey = "TxhTZggCaSo2Pf2Zx3h2ibiFDGXK9+fUvZZXlVFyiBM="

    public let keys: [FeedPublicKey]

    public init(keys: [FeedPublicKey]) {
        var seen = Set<FeedPublicKey>()
        self.keys = keys.filter { seen.insert($0).inserted }
    }

    /// Parses base64 keys, skipping (and never trusting) malformed ones.
    public init(base64Keys: [String]) {
        self.init(keys: base64Keys.compactMap(FeedPublicKey.init(text:)))
    }

    /// Whether any key is trusted (no keys: no remote feed and no cached copy is ever accepted).
    public var isEmpty: Bool { keys.isEmpty }

    /// This build's keys: the production keys, plus the test key in debug builds.
    public static var embedded: FeedTrust {
        #if DEBUG
        FeedTrust(base64Keys: productionKeys + [testKey])
        #else
        FeedTrust(base64Keys: productionKeys)
        #endif
    }

    /// Production keys only (what a release build trusts), for tools and tests.
    public static var production: FeedTrust { FeedTrust(base64Keys: productionKeys) }
}

/// Where the remote feed lives (DESIGN §7.2).
public enum FeedEndpoint {
    /// The published `feed.json` (GitHub Pages, behind the owner's domain once chosen). Nil until the owner publishes
    /// it: with no URL the app never fetches. Its signature is always `<url>.sig`.
    public static let production: URL? = nil

    /// The debug override: `SUDAMP_FEED_URL=<url>` points a debug build at a scratch feed (`http://127.0.0.1:<port>/…`
    /// is allowed for local test servers). Release builds ignore it.
    public static let environmentKey = "SUDAMP_FEED_URL"

    /// This process's feed URL: the debug override if set, else `production`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        #if DEBUG
        if let raw = environment[environmentKey], !raw.isEmpty { return URL(string: raw) }
        #endif
        return production
    }

    /// `<feed URL>.sig`: the last path component with `.sig` appended (`…/feed.json` → `…/feed.json.sig`).
    public static func signatureURL(for feedURL: URL) -> URL? {
        guard var c = URLComponents(url: feedURL, resolvingAgainstBaseURL: false), !c.path.isEmpty,
              !c.path.hasSuffix("/") else { return nil }
        c.path += ".sig"
        c.query = nil
        c.fragment = nil
        return c.url
    }

    /// Debug builds may fetch over plain HTTP from loopback test servers; release builds never do.
    public static var allowsLoopbackHTTP: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}
