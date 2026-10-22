// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

/// Checks a radio stream the way the catalog seed did: the host and the final (redirected) host resolve to public
/// addresses only, HTTP 200, an audio content type, and at least 4 chained MPEG/ADTS frames (or Ogg pages) in the
/// first 32 KB.
enum RadioCheck {
    struct Result: Encodable, Sendable {
        var ok: Bool
        var status: Int?
        var contentType: String?
        var finalHost: String?
        var bytes: Int
        var format: String?
        var frames: Int?
        var sampleRate: Int?
        var kbps: Int?
        var icyName: String?
        var ms: Double
        var error: String?
    }

    static let sniffBytes = 32_768

    static func check(_ url: URL, timeout: TimeInterval = 10) async -> Result {
        let started = ContinuousClock.now
        var r = Result(ok: false, bytes: 0, ms: 0)
        func done(_ error: String?) -> Result {
            r.error = error
            r.ok = error == nil
            r.ms = milliseconds(ContinuousClock.now - started)
            return r
        }
        do {
            _ = try await RadioHostCheck.check(url, resolver: SystemHostResolver())
        } catch {
            return done("\(error)")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(toolUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return done("not HTTP") }
            r.status = http.statusCode
            r.contentType = http.value(forHTTPHeaderField: "Content-Type")
            r.icyName = http.value(forHTTPHeaderField: "icy-name")
            r.finalHost = http.url?.host
            guard http.statusCode == 200 else { return done("HTTP \(http.statusCode)") }
            if let final = http.url, final.host != url.host {
                do { _ = try await RadioHostCheck.check(final, resolver: SystemHostResolver()) } catch {
                    return done("redirect target \(final.host ?? "?"): \(error)")
                }
            }
            var data = Data()
            data.reserveCapacity(sniffBytes)
            for try await b in bytes {
                data.append(b)
                if data.count >= sniffBytes { break }
            }
            r.bytes = data.count
            // ICY metadata interleaving (icy-metaint) can split frames; a 32 KB window holds several chains anyway.
            let type = (r.contentType ?? "").lowercased()
            let audioType = type.hasPrefix("audio/") || type.hasPrefix("application/ogg") || type.isEmpty
                || type.hasPrefix("application/octet-stream")
            guard let m = AudioSniffer.sniff(data) else { return done("no chained audio frames in \(data.count) bytes") }
            r.format = m.format.rawValue
            r.frames = m.chained
            r.sampleRate = m.sampleRate
            r.kbps = m.kbps
            guard audioType else { return done("content type \(type)") }
            guard data.count >= 8_192 else { return done("only \(data.count) bytes") }
            return done(nil)
        } catch {
            return done(error.localizedDescription)
        }
    }
}
