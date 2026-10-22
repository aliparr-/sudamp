// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation

/// DESIGN §6.4 failure classes; each drives a different back-off.
public enum ResolveFailureClass: String, Sendable, Codable, CaseIterable {
    /// Private, removed, geo-blocked, preview, DRM, Mixcloud restrictions: skip the stream for a while.
    case unavailable
    /// Timeouts, 5xx, DNS, dropped connections: retry once, then back off; may open the source breaker.
    case transient
    /// Format missing, JS challenge failure, 403, unknown errors: step up the JS ladder, then update.
    case engine
    /// "Sign in to confirm you're not a bot", rate limits, 429: degrade YouTube for hours.
    case botCheck
}

/// A classified resolve failure.
public struct ResolveFailure: Error, Sendable, Codable, Equatable, CustomStringConvertible {
    public var failureClass: ResolveFailureClass
    /// Stable short code, e.g. `mixcloudRepeatPlay`, `timeout`, `formatUnavailable`.
    public var reason: String
    /// The yt-dlp `ERROR:` line (or what was matched), for logs.
    public var message: String
    public var tier: Int = 1
    public var elapsedMs: Double = 0

    public init(_ failureClass: ResolveFailureClass, _ reason: String, message: String = "", tier: Int = 1,
                elapsedMs: Double = 0) {
        self.failureClass = failureClass
        self.reason = reason
        self.message = message
        self.tier = tier
        self.elapsedMs = elapsedMs
    }

    public var description: String { "\(failureClass.rawValue)/\(reason): \(message)" }
}

/// Maps yt-dlp's stderr (and our own timeout) to a failure class. Messages come from yt-dlp 2026.10.21
/// (`extractor/youtube/_video.py`, `extractor/mixcloud.py`, `extractor/common.py`, `networking/`), with
/// fixtures in `Fixtures/ytdlp/stderr/`. Rules are checked in order: bot-check, unavailable, transient, then
/// engine (anything unrecognised is treated as an engine problem, which steps up the JS ladder).
public enum ResolveErrorClassifier {
    struct Rule {
        let failureClass: ResolveFailureClass
        let reason: String
        let needles: [String]
    }

    static let rules: [Rule] = [
        // Bot checks and rate limits first: they also say "sign in" and "not available".
        Rule(failureClass: .botCheck, reason: "notABot", needles: ["confirm you're not a bot", "confirm you are not a bot"]),
        Rule(failureClass: .botCheck, reason: "captcha", needles: ["captcha challenge"]),
        Rule(failureClass: .botCheck, reason: "rateLimited", needles: ["this content isn't available, try again later",
                                                                       "rate-limited by youtube"]),
        Rule(failureClass: .botCheck, reason: "http429", needles: ["http error 429", "too many requests"]),
        Rule(failureClass: .botCheck, reason: "loginRequired", needles: ["login_required"]),

        // Mixcloud restrictedReason and exclusives (extractor/mixcloud.py).
        Rule(failureClass: .unavailable, reason: "mixcloudTracklist",
             needles: ["unavailable in your country due to licensing restrictions"]),
        Rule(failureClass: .unavailable, reason: "mixcloudRepeatPlay", needles: ["reached your play limit"]),
        Rule(failureClass: .unavailable, reason: "mixcloudRestricted", needles: ["track is restricted"]),
        Rule(failureClass: .unavailable, reason: "loginRequired",
             needles: ["only available for registered users", "login details are needed",
                       "this video is only available for registered users"]),
        // YouTube playability reasons (raise_no_formats / raise_geo_restricted).
        Rule(failureClass: .unavailable, reason: "ageRestricted",
             needles: ["confirm your age", "age-restricted", "inappropriate for some users"]),
        Rule(failureClass: .unavailable, reason: "private", needles: ["private video", "this video is private"]),
        Rule(failureClass: .unavailable, reason: "geoBlocked",
             needles: ["not available in your country", "not made this video available in your country",
                       "not available from your location", "geo restriction",
                       "geo-restricted", "georestricted"]),
        Rule(failureClass: .unavailable, reason: "membersOnly",
             needles: ["members-only", "join this channel", "available to this channel's members"]),
        Rule(failureClass: .unavailable, reason: "drm", needles: ["drm protected", "is drm-protected"]),
        Rule(failureClass: .unavailable, reason: "upcoming",
             needles: ["this live event will begin", "premieres in", "live event will begin in", "is_upcoming"]),
        Rule(failureClass: .unavailable, reason: "notLive", needles: ["not currently live"]),
        Rule(failureClass: .unavailable, reason: "removed",
             needles: ["video unavailable", "video is unavailable", "has been removed", "no longer available", "has been terminated",
                       "recording is not available", "http error 410", "track not found"]),
        Rule(failureClass: .unavailable, reason: "notFound", needles: ["http error 404", "404: not found"]),

        // Network trouble.
        Rule(failureClass: .transient, reason: "dns",
             needles: ["temporary failure in name resolution", "nodename nor servname", "name or service not known",
                       "failed to resolve", "getaddrinfo failed"]),
        Rule(failureClass: .transient, reason: "network",
             needles: ["timed out", "connection reset", "connection refused", "connection aborted",
                       "network is unreachable", "no route to host", "remote end closed connection",
                       "incompleteread", "eof occurred in violation of protocol", "ssl:", "unable to connect to proxy",
                       "transporterror", "unable to download webpage: <urlopen error"]),
        Rule(failureClass: .transient, reason: "http5xx",
             needles: ["http error 500", "http error 502", "http error 503", "http error 504",
                       "internal server error", "bad gateway", "service unavailable", "gateway timeout"]),

        // Extraction broke: the JS ladder and engine updates fix these.
        Rule(failureClass: .engine, reason: "challenge",
             needles: ["n challenge solving failed", "signature solving failed", "nsig extraction failed",
                       "signature extraction failed", "challenge solving"]),
        Rule(failureClass: .engine, reason: "formatUnavailable", needles: ["requested format is not available"]),
        Rule(failureClass: .engine, reason: "noFormats", needles: ["no video formats found", "only images are available"]),
        Rule(failureClass: .engine, reason: "http403", needles: ["http error 403"]),
        Rule(failureClass: .engine, reason: "unsupportedURL", needles: ["unsupported url"]),
        Rule(failureClass: .engine, reason: "extraction", needles: ["unable to extract", "please report this issue"]),
    ]

    /// Classifies a failed run. `timedOut` wins (our process-group kill at 10 s / 12 s).
    public static func classify(stderr: String, termination: Termination?, timedOut: Bool,
                                tier: Int = 1, elapsedMs: Double = 0) -> ResolveFailure {
        if timedOut {
            return ResolveFailure(.transient, "timeout", message: "killed after \(Int(elapsedMs)) ms", tier: tier,
                                  elapsedMs: elapsedMs)
        }
        let message = errorLine(stderr)
        // Normalise typographic apostrophes (YouTube sends "you’re").
        let haystack = stderr.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        let errorText = message.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
        // Prefer a match in the ERROR line; fall back to the whole stderr (warnings can explain the error).
        for text in [errorText, haystack] where !text.isEmpty {
            if let rule = rules.first(where: { $0.needles.contains(where: text.contains) }) {
                return ResolveFailure(rule.failureClass, rule.reason, message: message, tier: tier, elapsedMs: elapsedMs)
            }
        }
        let fallback = message.isEmpty ? "no error output (\(termination.map(\.description) ?? "unknown"))" : message
        return ResolveFailure(.engine, "unknown", message: fallback, tier: tier, elapsedMs: elapsedMs)
    }

    /// The last `ERROR:` line, else the last non-empty line.
    public static func errorLine(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.last { $0.hasPrefix("ERROR:") } ?? lines.last { !$0.isEmpty } ?? ""
    }

    /// `WARNING:` lines, logged as early signs of breakage (DESIGN §6.2).
    public static func warnings(_ stderr: String) -> [String] {
        stderr.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasPrefix("WARNING:") }
    }
}
