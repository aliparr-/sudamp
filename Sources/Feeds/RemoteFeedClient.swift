// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation

/// A fetched document before verification.
public struct RemoteFeedResponse: Sendable, Equatable {
    /// The exact bytes of `feed.json` (the signature covers these bytes).
    public let body: Data
    /// The contents of `feed.json.sig`.
    public let signature: Data
    public let etag: String?

    public init(body: Data, signature: Data, etag: String?) {
        self.body = body
        self.signature = signature
        self.etag = etag
    }
}

/// What one conditional fetch produced.
public enum RemoteFeedFetchResult: Sendable, Equatable {
    /// 304: the cached copy is still current.
    case notModified
    /// 200: a new body and its signature.
    case fetched(RemoteFeedResponse)
}

/// Why a fetch produced nothing usable. Every case leaves the active document unchanged.
public enum RemoteFeedError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The URL breaks the policy (HTTPS only; loopback HTTP in debug builds).
    case insecureURL(String)
    case httpStatus(Int, url: String)
    /// The body (or the signature file) is larger than the cap.
    case tooLarge(limit: Int)
    /// A 304 to a request that sent no `If-None-Match`.
    case unexpectedNotModified
    case notHTTP
    case timedOut
    case transport(String)

    public var description: String {
        switch self {
        case .insecureURL(let u): "refused URL \(u) (HTTPS only)"
        case .httpStatus(let s, let u): "HTTP \(s) from \(u)"
        case .tooLarge(let n): "response larger than \(n) bytes"
        case .unexpectedNotModified: "304 without If-None-Match"
        case .notHTTP: "not an HTTP response"
        case .timedOut: "timed out"
        case .transport(let m): m
        }
    }

    /// The HTTP status for `feed.status` (0 when there was none).
    public var httpStatus: Int {
        if case .httpStatus(let s, _) = self { return s }
        return 0
    }
}

/// Fetches `feed.json` and its signature (the M7 seam; tests stub it).
public protocol RemoteFeedFetching: Sendable {
    var feedURL: URL { get }
    /// A conditional GET of the feed (`If-None-Match: etag`), then the signature when the feed changed.
    func fetch(ifNoneMatch etag: String?) async throws(RemoteFeedError) -> RemoteFeedFetchResult
}

/// Which URLs the feed may come from (DESIGN §7.2): HTTPS on a named host, without userinfo; plain HTTP only to
/// `127.0.0.1`, `::1` or `localhost`, and only when `allowLoopbackHTTP` (debug builds' local test servers).
public enum FeedURLPolicy {
    public static func isAllowed(_ url: URL, allowLoopbackHTTP: Bool) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(),
              let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil else { return false }
        switch scheme {
        case "https": return true
        case "http": return allowLoopbackHTTP && ["127.0.0.1", "::1", "[::1]", "localhost"].contains(host)
        default: return false
        }
    }
}

/// URLSession client for the remote feed: conditional GET with `If-None-Match`, 304 handling, a size cap that stops
/// reading at the limit, per-request timeouts, no cookies, no cache, no credentials, `User-Agent: sudamp/<ver>` and
/// no identifiers (`Accept-Language` is fixed to `*` so the user's locale isn't sent). Redirects are followed only to
/// URLs the policy allows (GitHub Pages redirects to a custom domain).
public final class RemoteFeedClient: RemoteFeedFetching {
    /// `feed.json` is ~40 KB with 99 streams; 2 MiB leaves room for ~5,000.
    public static let defaultMaxBytes = 2 << 20

    public let feedURL: URL
    public let signatureURL: URL
    public let userAgent: String
    public let maxBytes: Int
    public let timeout: TimeInterval
    private let session: URLSession

    /// - Parameters:
    ///   - timeout: per request and per resource (the caller's launch budget is enforced by `FeedService`).
    ///   - configuration: copied; tests pass one with stub `protocolClasses`.
    public init(feedURL: URL, signatureURL: URL? = nil, userAgent: String = "sudamp/\(BuildInfo.version)",
                timeout: TimeInterval = 20, maxBytes: Int = RemoteFeedClient.defaultMaxBytes,
                allowLoopbackHTTP: Bool = FeedEndpoint.allowsLoopbackHTTP,
                configuration: URLSessionConfiguration = .ephemeral) throws(RemoteFeedError) {
        guard FeedURLPolicy.isAllowed(feedURL, allowLoopbackHTTP: allowLoopbackHTTP) else {
            throw .insecureURL(feedURL.absoluteString)
        }
        guard let sig = signatureURL ?? FeedEndpoint.signatureURL(for: feedURL),
              FeedURLPolicy.isAllowed(sig, allowLoopbackHTTP: allowLoopbackHTTP) else {
            throw .insecureURL(signatureURL?.absoluteString ?? feedURL.absoluteString + ".sig")
        }
        self.feedURL = feedURL
        self.signatureURL = sig
        self.userAgent = userAgent
        self.maxBytes = maxBytes
        self.timeout = timeout
        let config = configuration
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: RedirectGuard(allowLoopbackHTTP: allowLoopbackHTTP),
                             delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func fetch(ifNoneMatch etag: String?) async throws(RemoteFeedError) -> RemoteFeedFetchResult {
        let feed = try await get(feedURL, ifNoneMatch: etag, limit: maxBytes)
        guard let body = feed.body else {
            guard etag != nil else { throw .unexpectedNotModified }
            return .notModified
        }
        let sig = try await get(signatureURL, ifNoneMatch: nil, limit: FeedSignature.maxFileBytes)
        guard let signature = sig.body else { throw .unexpectedNotModified }
        return .fetched(RemoteFeedResponse(body: body, signature: signature, etag: feed.etag))
    }

    /// One GET. `body` is nil on 304; any other non-200 status throws.
    private func get(_ url: URL, ifNoneMatch etag: String?, limit: Int) async throws(RemoteFeedError)
        -> (body: Data?, etag: String?) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // CFNetwork would otherwise send the user's locale (`en-GB,en;q=0.9`): a fixed value identifies no one.
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw RemoteFeedError.notHTTP }
            if http.statusCode == 304 { return (nil, http.value(forHTTPHeaderField: "ETag") ?? etag) }
            guard http.statusCode == 200 else {
                throw RemoteFeedError.httpStatus(http.statusCode, url: http.url?.absoluteString ?? url.absoluteString)
            }
            if http.expectedContentLength > Int64(limit) { throw RemoteFeedError.tooLarge(limit: limit) }
            var data = Data()
            data.reserveCapacity(Int(min(max(http.expectedContentLength, 0), Int64(limit))))
            for try await byte in bytes {
                guard data.count < limit else { throw RemoteFeedError.tooLarge(limit: limit) }
                data.append(byte)
            }
            return (data, http.value(forHTTPHeaderField: "ETag"))
        } catch let e as RemoteFeedError {
            throw e
        } catch let e as URLError where e.code == .timedOut {
            throw .timedOut
        } catch is CancellationError {
            throw .transport("cancelled")
        } catch {
            throw .transport(error.localizedDescription)
        }
    }
}

/// Refuses redirects to URLs `FeedURLPolicy` doesn't allow (an HTTPS → HTTP downgrade surfaces as the 3xx status).
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let allowLoopbackHTTP: Bool

    init(allowLoopbackHTTP: Bool) { self.allowLoopbackHTTP = allowLoopbackHTTP }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, FeedURLPolicy.isAllowed(url, allowLoopbackHTTP: allowLoopbackHTTP) else { return nil }
        return request
    }
}
