// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation

public enum ResolverError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Radio streams are played directly; they never reach yt-dlp.
    case notResolvable(SourceKind)
    case invalidRequest(String)
    case engineMissing
    /// Tier 2 needs the QuickJS-NG path.
    case tierUnavailable(ResolveTier)
    /// A user pick killed this background resolve.
    case preempted

    public var description: String {
        switch self {
        case let .notResolvable(s): "\(s.rawValue) streams are not resolved"
        case let .invalidRequest(m): "invalid request: \(m)"
        case .engineMissing: "no yt-dlp engine installed"
        case let .tierUnavailable(t): "tier \(t.rawValue) unavailable (no QuickJS-NG)"
        case .preempted: "pre-empted by a user pick"
        }
    }
}

/// The exact yt-dlp command for one resolve (DESIGN §6.2). Pure, so argv goldens are unit-tested.
public struct EngineInvocation: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var timeout: Duration

    public var spec: SubprocessSpec {
        SubprocessSpec(executable: executable, arguments: arguments, environment: environment,
                       workingDirectory: workingDirectory, timeout: timeout)
    }

    /// - Parameters:
    ///   - cacheDirectory: `layout.cacheDir`, or `layout.canaryCacheDir` for the canary.
    ///   - qjs: QuickJS-NG executable (`<app>/Contents/Helpers/qjs`), required for tier 2.
    ///   - proxy: an HTTP(S) proxy from the system settings, when one is set.
    public static func make(request: ResolveRequest, tier: ResolveTier, settings: ResolverSettings,
                            layout: EngineLayout, engine: URL, qjs: URL?, proxy: URL? = nil,
                            cacheDirectory: URL? = nil) throws -> EngineInvocation {
        guard request.source.needsResolver else { throw ResolverError.notResolvable(request.source) }
        try validate(request)
        let settings = settings.validated().settings

        var argv = ["--ignore-config", "--no-plugin-dirs", "--no-update",
                    // Must precede --js-runtimes, or yt-dlp's default Deno (preference 1000) stays enabled.
                    "--no-js-runtimes"]
        if tier == .quickjs {
            guard let qjs else { throw ResolverError.tierUnavailable(tier) }
            argv += ["--js-runtimes", "quickjs:\(qjs.path)"]
        }
        if let proxy {
            guard ["http", "https"].contains(proxy.scheme?.lowercased() ?? ""), proxy.host != nil else {
                throw ResolverError.invalidRequest("proxy must be http(s)://host:port")
            }
            argv += ["--proxy", proxy.absoluteString]
        }
        argv += ["--cache-dir", (cacheDirectory ?? layout.cacheDir).path,
                 "--no-playlist", "--socket-timeout", String(settings.socketTimeout), "-J"]
        argv += sourceFlags(request.source, tier: tier, settings: settings)
        argv += ["--", request.url.absoluteString]

        return EngineInvocation(executable: engine, arguments: argv, environment: layout.environment,
                                workingDirectory: layout.home, timeout: settings.timeout(for: tier))
    }

    /// Per-source flags (DESIGN §6.2 table). YouTube VOD and `/live` both take the tier's `player_client` list,
    /// which is the JS ladder ("order and clients from the feed").
    static func sourceFlags(_ source: SourceKind, tier: ResolveTier, settings: ResolverSettings) -> [String] {
        var flags: [String] = []
        if source == .youtube || source == .youtubeLive, let clients = settings.clientList(for: tier) {
            flags += ["--extractor-args", "youtube:player_client=\(clients)"]
        }
        for arg in settings.extractorArgs[source] ?? [] { flags += ["--extractor-args", arg] }
        if let format = settings.formats[source] { flags += ["-f", format] }
        return flags
    }

    static func validate(_ request: ResolveRequest) throws {
        let url = request.url
        guard url.scheme == "https" else { throw ResolverError.invalidRequest("not https: \(url.absoluteString)") }
        guard url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            throw ResolverError.invalidRequest("userinfo or port in \(url.absoluteString)")
        }
        guard let host = url.host?.lowercased(), ResolveRequest.pageHosts(for: request.source).contains(host) else {
            throw ResolverError.invalidRequest("host \(url.host ?? "nil") is not a \(request.source.rawValue) page")
        }
    }
}
