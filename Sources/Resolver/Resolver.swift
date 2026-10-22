// SPDX-License-Identifier: GPL-3.0-or-later

/// Resolver (DESIGN §4, §6): EngineStore delivers the isolated yt-dlp build; ResolverService turns a stream page
/// into a playable `ResolvedStream` through it. Pure value types plus two actors; no AppKit or AVFoundation.
public enum ResolverModule {
    public static let name = "Resolver"
}
