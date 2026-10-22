// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// Radio redirects under the private-address rule (DESIGN §7.1; PLAN M6 security item). FFmpeg follows HTTP
/// redirects on its own, so a station (or a pasted URL) could send it to `127.0.0.1`, the LAN or `169.254.169.254`
/// after our DNS check of the first host. So FFmpeg follows none (`max_redirects=0`): we follow them, one hop at a
/// time, each target re-checked with `RadioURLPolicy` and `RadioHostCheck`. To cost nothing in the steady state the
/// controller remembers how many hops each station took last time: it walks exactly that many (our requests replace
/// FFmpeg's own, one for one) and hands FFmpeg the last checked URL, which is never fetched twice. If FFmpeg then
/// fails, one more hop is tried. Residual risks: DNS rebinding between our lookup and FFmpeg's, HLS segment hosts,
/// and redirects only FFmpeg understands (an `ICY 302` status line), which fail to open instead of being followed.
nonisolated public enum RadioRedirects {
    public static let maxHops = 5

    public struct Walk: Sendable, Equatable {
        /// The URL to open (every hop up to it was checked).
        public var url: URL
        public var hops: Int
        /// `url` answered without redirecting (false: it was not fetched, because the hop budget was reached or a
        /// request failed; FFmpeg, following nothing, finds out).
        public var complete: Bool
        public var ms: Double
    }

    public enum WalkError: Error, Sendable, Equatable {
        /// A redirect pointed at a URL or host the radio rule rejects.
        case rejectedHop(String, CanonicalError)
        case tooManyRedirects
    }

    /// Follows at most `hops` redirects from `start` (already checked), checking each target, and returns the last
    /// checked URL. `hops == 0` makes no request.
    public static func walk(_ start: URL, hosts: any HostResolving, fetch: any RedirectFetching, hops limit: Int)
        async throws -> Walk {
        let started = ContinuousClock.now
        var url = start
        var hop = 0
        while hop < min(limit, maxHops) {
            let next: URL?
            do {
                next = try await fetch.redirectTarget(of: url)
            } catch {
                return Walk(url: url, hops: hop, complete: false, ms: ms(since: started))
            }
            guard let next else { return Walk(url: url, hops: hop, complete: true, ms: ms(since: started)) }
            url = try await check(next, hosts: hosts)
            hop += 1
        }
        return Walk(url: url, hops: hop, complete: false, ms: ms(since: started))
    }

    /// One hop: the redirect target of `url`, checked, or nil when `url` doesn't redirect.
    public static func next(after url: URL, hops: Int, hosts: any HostResolving, fetch: any RedirectFetching)
        async throws -> URL? {
        guard hops < maxHops else { throw WalkError.tooManyRedirects }
        guard let next = try await fetch.redirectTarget(of: url) else { return nil }
        return try await check(next, hosts: hosts)
    }

    static func check(_ url: URL, hosts: any HostResolving) async throws -> URL {
        do {
            return try await RadioHostCheck.check(url, resolver: hosts)
        } catch let e as CanonicalError {
            throw WalkError.rejectedHop(url.absoluteString, e)
        }
    }

    private static func ms(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return (Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15).rounded()
    }
}

/// One request of the walk: the redirect target of `url`, or nil when it answers without redirecting.
nonisolated public protocol RedirectFetching: Sendable {
    func redirectTarget(of url: URL) async throws -> URL?
}

/// A GET that never follows a redirect and is cancelled as soon as the headers arrive (a station's body never ends).
/// No cookies, no cache; the system proxy applies as for every URLSession request. ATS limits it to HTTPS, which
/// every curated station uses; a plain-HTTP URL ends the walk at its first hop.
nonisolated public struct URLSessionRedirectFetcher: RedirectFetching {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 4) { self.timeout = timeout }

    public func redirectTarget(of url: URL) async throws -> URL? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { return nil }
        guard [301, 302, 303, 307, 308].contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else { return nil }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }

    nonisolated private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
