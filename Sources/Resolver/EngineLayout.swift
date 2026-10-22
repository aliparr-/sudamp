// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation

/// Where the engine lives and the private directories every yt-dlp run sees (DESIGN §6.2, §10). Derived from
/// `Core.Paths`, so `--profile <P>` / `SUDAMP_HOME` isolate the engine too.
public struct EngineLayout: Sendable, Equatable {
    /// `<AS>/engines/yt-dlp`: one directory per version, plus `current.json` and `<ver>.partial/` downloads.
    public let enginesRoot: URL
    /// `<AS>/engine-home`: yt-dlp's HOME, so the user's `~/.config/yt-dlp` (config and plugins) is never seen.
    public let home: URL
    /// `<Caches>/xdg`.
    public let xdgCache: URL
    /// `<Caches>/tmp`.
    public let tmp: URL
    /// `<Caches>/yt-dlp`: the one `--cache-dir` shared by serial resolves.
    public let cacheDir: URL
    /// `<Caches>/yt-dlp-canary`: the canary's own `--cache-dir`, so two processes never share one.
    public let canaryCacheDir: URL

    public init(paths: Paths) {
        enginesRoot = paths.engines.appending(path: "yt-dlp", directoryHint: .isDirectory)
        home = paths.engineHome
        xdgCache = paths.caches.appending(path: "xdg", directoryHint: .isDirectory)
        tmp = paths.caches.appending(path: "tmp", directoryHint: .isDirectory)
        cacheDir = paths.caches.appending(path: "yt-dlp", directoryHint: .isDirectory)
        canaryCacheDir = paths.caches.appending(path: "yt-dlp-canary", directoryHint: .isDirectory)
    }

    /// `<engine-home>/.config`.
    public var xdgConfig: URL { home.appending(path: ".config", directoryHint: .isDirectory) }

    /// The complete, scrubbed environment of every yt-dlp child (nothing is inherited from the app).
    /// `YTDLP_NO_PLUGINS=1` disables plugin loading outright (`yt_dlp/plugins.py` `load_plugins`), on top of the
    /// private HOME/XDG directories and `--no-plugin-dirs`.
    public var environment: [String: String] {
        [
            "HOME": home.path,
            "XDG_CONFIG_HOME": xdgConfig.path,
            "XDG_CACHE_HOME": xdgCache.path,
            "TMPDIR": tmp.path,
            "PATH": "/usr/bin:/bin",
            "LANG": "en_US.UTF-8",
            "YTDLP_NO_PLUGINS": "1",
        ]
    }

    /// Creates the private directories (yt-dlp fails if TMPDIR is missing).
    public func createDirectories() throws {
        for dir in [enginesRoot, home, xdgConfig, xdgCache, tmp, cacheDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func versionDirectory(_ version: String) -> URL {
        enginesRoot.appending(path: version, directoryHint: .isDirectory)
    }

    public func partialDirectory(_ version: String) -> URL {
        enginesRoot.appending(path: "\(version).partial", directoryHint: .isDirectory)
    }

    public var currentFile: URL { enginesRoot.appending(path: "current.json") }
    /// Update bookkeeping (M6): last checks, switches, rejected versions, the `_update_spec` identifier.
    public var updatesFile: URL { enginesRoot.appending(path: "updates.json") }
}

extension Duration {
    /// Whole duration in milliseconds as a Double.
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
