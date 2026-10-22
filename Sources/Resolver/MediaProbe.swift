// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The result of a 64 KB range GET on a resolved media URL.
public enum MediaProbeResult: Sendable, Equatable {
    case ok(status: Int, bytes: Int, ms: Double)
    /// HTTP 403 on a fresh URL: an engine-class failure (DESIGN §6.3, §6.4).
    case forbidden(status: Int)
    case failed(String)
}

/// Probes progressive YouTube URLs after prefetch (DESIGN §6.3: "progressive YouTube URLs also get a 64 KB range GET
/// after `available_at` (a 403 is an engine error), HLS and radio aren't probed").
public protocol MediaProbing: Sendable {
    func probe(_ stream: ResolvedStream, proxy: URL?) async -> MediaProbeResult
}

/// URLSession range GET with yt-dlp's headers. URLSession follows the system proxy by itself; an explicit `proxy`
/// (the debug `SUDAMP_PROXY` override) is set on the session as well.
public struct URLSessionMediaProbe: MediaProbing {
    public static let rangeBytes = 65_536
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 8) { self.timeout = timeout }

    public func probe(_ stream: ResolvedStream, proxy: URL?) async -> MediaProbeResult {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        if let proxy, let host = proxy.host, let port = proxy.port {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
            ]
        }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: stream.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        for (name, value) in stream.httpHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-\(Self.rangeBytes - 1)", forHTTPHeaderField: "Range")
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ms = (ContinuousClock.now - started).milliseconds
            switch status {
            case 200, 206: return .ok(status: status, bytes: data.count, ms: ms)
            case 403: return .forbidden(status: status)
            default: return .failed("HTTP \(status)")
            }
        } catch {
            return .failed("\(error.localizedDescription)")
        }
    }
}
