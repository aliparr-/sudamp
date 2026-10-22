// SPDX-License-Identifier: GPL-3.0-or-later
import CFNetwork
import Foundation

/// The proxy yt-dlp (`--proxy`) and mpv (`http-proxy`) should use (DESIGN §6.2 "System proxy"). Neither reads the
/// macOS settings itself (yt-dlp runs in a scrubbed environment, FFmpeg ignores them), so Resolver and Playback
/// pass the system's HTTP(S) proxy explicitly. Both take a plain `http://host:port` proxy and tunnel HTTPS
/// through it with CONNECT.
public struct ProxyResolution: Sendable, Equatable, CustomStringConvertible {
    public enum Origin: String, Sendable, Equatable, Codable {
        /// No proxy configured.
        case none
        /// From `CFNetworkCopySystemProxySettings`.
        case system
        /// The debug-only `SUDAMP_PROXY` override.
        case override
    }

    /// `http://host:port`, or nil for direct connections.
    public var url: URL?
    public var origin: Origin
    /// Why no proxy is used although one is configured (PAC-only, SOCKS-only, a malformed entry).
    public var unsupported: String?

    public init(url: URL?, origin: Origin, unsupported: String? = nil) {
        self.url = url
        self.origin = origin
        self.unsupported = unsupported
    }

    public static let direct = ProxyResolution(url: nil, origin: .none)

    public var description: String {
        if let url { return "\(origin.rawValue) proxy \(url.absoluteString)" }
        return unsupported.map { "direct (\($0))" } ?? "direct"
    }
}

public enum SystemProxy {
    /// Keys of the `CFNetworkCopySystemProxySettings` dictionary (`kCFNetworkProxies*`; the macOS-only ones are
    /// spelled out because CFNetwork exports them only to Objective-C on some SDKs).
    enum Key {
        static let httpEnable = "HTTPEnable", httpProxy = "HTTPProxy", httpPort = "HTTPPort"
        static let httpsEnable = "HTTPSEnable", httpsProxy = "HTTPSProxy", httpsPort = "HTTPSPort"
        static let socksEnable = "SOCKSEnable"
        static let pacEnable = "ProxyAutoConfigEnable", wpadEnable = "ProxyAutoDiscoveryEnable"
    }

    /// Pure mapping from a settings dictionary. The HTTPS proxy wins (all of sudamp's media is HTTPS), then the HTTP
    /// proxy; PAC/WPAD-only and SOCKS-only setups map to no proxy with the reason, as DESIGN §6.2 specifies.
    public static func resolve(settings: [String: Any]) -> ProxyResolution {
        for (enable, host, port) in [(Key.httpsEnable, Key.httpsProxy, Key.httpsPort),
                                     (Key.httpEnable, Key.httpProxy, Key.httpPort)] where flag(settings[enable]) {
            guard let h = settings[host] as? String, !h.isEmpty else { continue }
            guard let p = number(settings[port]), (1...65535).contains(p) else {
                return ProxyResolution(url: nil, origin: .none, unsupported: "\(host) \(h) has no valid port")
            }
            guard let url = proxyURL(host: h, port: p) else {
                return ProxyResolution(url: nil, origin: .none, unsupported: "\(host) \(h) is not a host name")
            }
            return ProxyResolution(url: url, origin: .system)
        }
        if flag(settings[Key.pacEnable]) || flag(settings[Key.wpadEnable]) {
            return ProxyResolution(url: nil, origin: .none, unsupported: "PAC/WPAD-only proxy configuration is unsupported")
        }
        if flag(settings[Key.socksEnable]) {
            return ProxyResolution(url: nil, origin: .none, unsupported: "SOCKS-only proxy configuration is unsupported")
        }
        return .direct
    }

    /// `SUDAMP_PROXY=<http://host:port>` (debug builds only; `direct` forces no proxy). Nil when unset or in release.
    public static func override(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProxyResolution? {
        #if DEBUG
        guard let raw = environment["SUDAMP_PROXY"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw == "direct" || raw == "none" { return ProxyResolution(url: nil, origin: .override) }
        guard let c = URLComponents(string: raw), c.scheme?.lowercased() == "http", let host = c.host, !host.isEmpty,
              let port = c.port, let url = proxyURL(host: host, port: port) else {
            return ProxyResolution(url: nil, origin: .override, unsupported: "SUDAMP_PROXY must be http://host:port")
        }
        return ProxyResolution(url: url, origin: .override)
        #else
        return nil
        #endif
    }

    /// The proxy to use right now: the debug override, else the system settings. Cheap enough to call before every
    /// resolve and load (DESIGN §6.2), so a proxy change applies to the next stream.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> ProxyResolution {
        if let o = override(environment: environment) { return o }
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return .direct
        }
        return resolve(settings: settings)
    }

    /// `http://host:port`; IPv6 literals are bracketed. Hosts with characters outside a URL host are refused.
    static func proxyURL(host raw: String, port: Int) -> URL? {
        let host = raw.trimmingCharacters(in: .whitespaces)
        guard (1...65535).contains(port), !host.isEmpty, host.count <= 253 else { return nil }
        let isIPv6 = host.contains(":")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
            + (isIPv6 ? ":" : ""))
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard bare.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "http://\(bare.contains(":") ? "[\(bare)]" : bare):\(port)")
    }

    private static func flag(_ v: Any?) -> Bool { number(v).map { $0 != 0 } ?? false }

    private static func number(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: n.intValue
        case let i as Int: i
        case let s as String: Int(s)
        default: nil
        }
    }
}
