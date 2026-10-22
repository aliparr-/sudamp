// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Foundation

extension ResolverSettings {
    /// The feed's engine strings (DESIGN §7.1 `engine`: `clients`, `formats`, `extractorArgs`, `mediaHosts`). The feed
    /// decoder has already validated them (§7.2); `ResolverService` validates again before anything reaches argv.
    public init(engine: EngineConfig) {
        var formats = engine.formats
        formats[.radio] = nil
        var extractorArgs = engine.extractorArgs
        extractorArgs[.radio] = nil
        self.init(clients: engine.clients.isEmpty ? Self.defaultClients : engine.clients, formats: formats,
                  extractorArgs: extractorArgs, mediaHosts: Self.mediaHosts(fromFeed: engine.mediaHosts))
    }

    /// The feed lists media-host suffixes as one flat list; the Resolver checks them per source. Each R1 suffix
    /// (`ResolverSettings.defaultMediaHosts`) applies to its own sources only, so a feed listing
    /// `googlevideo.com` doesn't let a Mixcloud resolve land on a YouTube host. A suffix R1 never saw is a CDN move
    /// the feed is announcing, so it applies to every resolved source. A source left without any suffix keeps its
    /// R1 default: a short list in the feed can extend the allowlist but never silently break a source (its kill
    /// switch is the way to turn one off).
    public static func mediaHosts(fromFeed suffixes: [String]) -> [SourceKind: [String]] {
        let known = Set(defaultMediaHosts.values.flatMap { $0 })
        let extra = suffixes.filter { !known.contains($0) && EngineStrings.isHostSuffix($0) }
        var out: [SourceKind: [String]] = [:]
        for (source, defaults) in defaultMediaHosts {
            let listed = suffixes.filter { defaults.contains($0) }
            var list = listed.isEmpty ? defaults : listed
            for s in extra where !list.contains(s) { list.append(s) }
            out[source] = list
        }
        return out
    }
}
