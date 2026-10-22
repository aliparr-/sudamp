// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Rules for curated and pasted internet-radio URLs (DESIGN §7.1 "Radio URLs"): http(s) on a real hostname (no IP
/// literal, localhost, `.local`, `.internal` or single label), no userinfo, port 80, 443 or 1024–65535, and a direct
/// stream rather than a playlist file. The DNS half of the rule is `RadioHostCheck`.
public enum RadioURLPolicy {
    /// Special-use and private names (RFC 6761/6762/8375 and common LAN suffixes) that never name a public server.
    static let forbiddenSuffixes = [
        "localhost", "local", "internal", "localdomain", "home.arpa", "lan", "arpa", "test", "invalid",
        "example", "onion", "intranet", "corp", "home",
    ]
    /// Playlist-file extensions: mpv would follow their entries, so only the stream itself may be curated. HLS
    /// (`.m3u8`) is a stream format mpv plays natively under `load-unsafe-playlists=no`, so it is allowed.
    static let playlistExtensions: Set<String> = ["pls", "m3u", "asx", "xspf", "ram", "wax", "wvx", "smil", "qtl"]

    /// Returns the normalised URL (lower-case scheme and host, default port and fragment removed) or throws why not.
    public static func validate(_ input: String) throws(CanonicalError) -> URL {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 2048, !Canonicaliser.containsUnsafeCharacters(s),
              let c = URLComponents(string: s), let rawScheme = c.scheme else { throw .malformedURL }
        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else { throw .unsupportedScheme(scheme) }
        guard c.percentEncodedUser == nil, c.percentEncodedPassword == nil, !authority(of: s).contains("@") else {
            throw .userinfo
        }
        guard let encodedHost = c.percentEncodedHost, !encodedHost.isEmpty else { throw .malformedURL }
        let host = try validateHost(encodedHost)
        if let port = c.port {
            guard port == 80 || port == 443 || (1024...65535).contains(port) else { throw .invalidPort(port) }
        }
        let last = c.percentEncodedPath.split(separator: "/").last.map(String.init) ?? ""
        if let dot = last.lastIndex(of: "."), playlistExtensions.contains(last[last.index(after: dot)...].lowercased()) {
            throw .notDirectStream
        }

        var out = URLComponents()
        out.scheme = scheme
        out.percentEncodedHost = host
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = c.port, port != defaultPort { out.port = port }
        out.percentEncodedPath = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        out.percentEncodedQuery = c.percentEncodedQuery
        guard let url = out.url else { throw .malformedURL }
        return url
    }

    /// Validates a host name and returns it lower-cased without a trailing dot.
    public static func validateHost(_ raw: String) throws(CanonicalError) -> String {
        var host = raw.lowercased()
        if host.hasPrefix("[") || host.contains(":") { throw .ipLiteral }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253, !host.contains("%") else { throw .invalidHost }
        if IPAddress(host) != nil { throw .ipLiteral }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2 else { throw host == "localhost" ? .forbiddenHost(host) : .singleLabelHost }
        for suffix in forbiddenSuffixes where host == suffix || host.hasSuffix("." + suffix) {
            throw .forbiddenHost(host)
        }
        for label in labels {
            guard label.wholeMatch(of: #/[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?/#) != nil else { throw .invalidHost }
        }
        // A numeric or hex top-level label means an IP address in disguise (`127.1`, `0x7f.0.0.1`): real TLDs are
        // alphabetic or IDNA (`xn--`).
        guard labels.last!.wholeMatch(of: #/[a-z]{2,63}|xn--[a-z0-9-]{1,59}/#) != nil else { throw .ipLiteral }
        return host
    }

    /// The authority part of a URL string (between `//` and the next `/`, `?` or `#`).
    private static func authority(of s: String) -> Substring {
        guard let r = s.range(of: "//") else { return "" }
        let rest = s[r.upperBound...]
        return rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    }
}

/// An IPv4 or IPv6 address, as returned by DNS.
public enum IPAddress: Hashable, Sendable, CustomStringConvertible {
    case v4(UInt32)
    /// 128 bits as (high, low) 64-bit halves.
    case v6(UInt64, UInt64)

    /// Parses dotted-quad IPv4 or textual IPv6 (via `inet_pton`, which rejects the legacy `127.1` forms).
    public init?(_ string: String) {
        var a4 = in_addr()
        if inet_pton(AF_INET, string, &a4) == 1 {
            self = .v4(UInt32(bigEndian: a4.s_addr))
            return
        }
        var a6 = in6_addr()
        if inet_pton(AF_INET6, string, &a6) == 1 {
            self = IPAddress(bytes: withUnsafeBytes(of: &a6) { Array($0) })
            return
        }
        return nil
    }

    /// From 4 or 16 network-order bytes.
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 4 || bytes.count == 16, "IPAddress needs 4 or 16 bytes")
        if bytes.count == 4 {
            self = .v4(bytes.reduce(0) { $0 << 8 | UInt32($1) })
        } else {
            let hi = bytes[0..<8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let lo = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            self = .v6(hi, lo)
        }
    }

    public var description: String {
        switch self {
        case .v4(let v):
            return "\(v >> 24).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
        case .v6(let hi, let lo):
            var a6 = in6_addr()
            withUnsafeMutableBytes(of: &a6) { buf in
                for i in 0..<8 { buf[i] = UInt8(truncatingIfNeeded: hi >> (56 - 8 * UInt64(i))) }
                for i in 0..<8 { buf[8 + i] = UInt8(truncatingIfNeeded: lo >> (56 - 8 * UInt64(i))) }
            }
            var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &a6, &out, socklen_t(out.count)) != nil else { return "?" }
            return String(decoding: out.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// True for globally routable unicast. False for loopback, private (RFC 1918, ULA), link-local, CGNAT,
    /// unspecified, multicast, documentation, benchmarking and reserved ranges, and for IPv6 forms that embed a
    /// non-public IPv4 address (mapped, NAT64, 6to4).
    public var isPublic: Bool {
        switch self {
        case .v4(let a):
            return !IPAddress.v4Blocked.contains { a & $0.mask == $0.net }
        case .v6(let hi, let lo):
            if hi == 0 && lo >> 32 == 0xFFFF { return IPAddress.v4(UInt32(truncatingIfNeeded: lo)).isPublic } // ::ffff:a.b.c.d
            if hi == 0x0064_FF9B_0000_0000 && lo >> 32 == 0 {                                           // 64:ff9b::/96
                return IPAddress.v4(UInt32(truncatingIfNeeded: lo)).isPublic
            }
            if hi >> 48 == 0x2002 { return IPAddress.v4(UInt32(truncatingIfNeeded: hi >> 16)).isPublic }  // 6to4
            guard hi >> 61 == 0b001 else { return false }   // only 2000::/3 is global unicast
            if hi >> 32 == 0x2001_0DB8 { return false }     // documentation
            if hi >> 32 == 0x2001_0000 { return false }     // Teredo tunnels hide the real endpoint
            if hi >> 44 == 0x3_FFF0 { return false }        // 3fff::/20 documentation (RFC 9637)
            return true
        }
    }

    private static let v4Blocked: [(net: UInt32, mask: UInt32)] = [
        (0x0000_0000, 0xFF00_0000), // 0.0.0.0/8 "this network"
        (0x0A00_0000, 0xFF00_0000), // 10.0.0.0/8 private
        (0x6440_0000, 0xFFC0_0000), // 100.64.0.0/10 CGNAT
        (0x7F00_0000, 0xFF00_0000), // 127.0.0.0/8 loopback
        (0xA9FE_0000, 0xFFFF_0000), // 169.254.0.0/16 link-local
        (0xAC10_0000, 0xFFF0_0000), // 172.16.0.0/12 private
        (0xC000_0000, 0xFFFF_FF00), // 192.0.0.0/24 IETF protocol assignments
        (0xC000_0200, 0xFFFF_FF00), // 192.0.2.0/24 TEST-NET-1
        (0xC058_6300, 0xFFFF_FF00), // 192.88.99.0/24 6to4 relay
        (0xC0A8_0000, 0xFFFF_0000), // 192.168.0.0/16 private
        (0xC612_0000, 0xFFFE_0000), // 198.18.0.0/15 benchmarking
        (0xC633_6400, 0xFFFF_FF00), // 198.51.100.0/24 TEST-NET-2
        (0xCB00_7100, 0xFFFF_FF00), // 203.0.113.0/24 TEST-NET-3
        (0xE000_0000, 0xF000_0000), // 224.0.0.0/4 multicast
        (0xF000_0000, 0xF000_0000), // 240.0.0.0/4 reserved, incl. broadcast
    ]
}

/// Resolves host names. Injectable so the radio DNS rule is testable with fixed answers.
public protocol HostResolving: Sendable {
    func addresses(for host: String) async throws -> [IPAddress]
}

/// The DNS half of the radio rule (DESIGN §7.1): before playback the host is resolved, and loopback, private and
/// link-local answers are rejected. Every answer must be public, so a DNS reply mixing a public and a private
/// address (a rebinding trick) is refused too.
public enum RadioHostCheck {
    /// Pure check over already-resolved addresses.
    public static func validate(addresses: [IPAddress]) throws(CanonicalError) {
        guard !addresses.isEmpty else { throw .unresolvable }
        if let bad = addresses.first(where: { !$0.isPublic }) { throw .nonPublicAddress(bad.description) }
    }

    /// Validates the URL, resolves its host with `resolver` and checks every answer.
    public static func check(_ url: URL, resolver: any HostResolving) async throws -> URL {
        let normalised = try RadioURLPolicy.validate(url.absoluteString)
        guard let host = normalised.host() else { throw CanonicalError.malformedURL }
        let addresses: [IPAddress]
        do { addresses = try await resolver.addresses(for: host) } catch { throw CanonicalError.unresolvable }
        try validate(addresses: addresses)
        return normalised
    }
}

/// `getaddrinfo` on a background queue (it blocks, so it must not run on the cooperative pool or the main thread).
public struct SystemHostResolver: HostResolving {
    public init() {}

    public func addresses(for host: String) async throws -> [IPAddress] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try SystemHostResolver.lookup(host) })
            }
        }
    }

    static func lookup(_ host: String) throws -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &result)
        guard rc == 0, let first = result else { throw CanonicalError.unresolvable }
        defer { freeaddrinfo(first) }
        var out: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            if let sa = ai.pointee.ai_addr {
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    let sin = UnsafeRawPointer(sa).load(as: sockaddr_in.self)
                    out.append(.v4(UInt32(bigEndian: sin.sin_addr.s_addr)))
                case AF_INET6:
                    var sin6 = UnsafeRawPointer(sa).load(as: sockaddr_in6.self)
                    out.append(IPAddress(bytes: withUnsafeBytes(of: &sin6.sin6_addr) { Array($0) }))
                default:
                    break
                }
            }
            cursor = ai.pointee.ai_next
        }
        return Array(Set(out))
    }
}
