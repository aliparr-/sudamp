import Foundation

/// Where sudamp keeps its state (DESIGN §10 "Profiles"). With a profile directory `P` (from `--profile <P>` or
/// `SUDAMP_HOME=<P>`), Application Support/sudamp maps to `P/`, Caches/sudamp to `P/Caches/` and Logs/sudamp to
/// `P/Logs/`, so every app-level test can run in a fresh `mktemp -d`.
public struct Paths: Sendable, Equatable {
    /// `~/Library/Application Support/sudamp` or the profile root.
    public let appSupport: URL
    /// `~/Library/Caches/sudamp` or `<profile>/Caches`.
    public let caches: URL
    /// `~/Library/Logs/sudamp` or `<profile>/Logs`.
    public let logs: URL
    /// True when running in an isolated profile.
    public let isProfile: Bool

    public init(appSupport: URL, caches: URL, logs: URL, isProfile: Bool) {
        self.appSupport = appSupport
        self.caches = caches
        self.logs = logs
        self.isProfile = isProfile
    }

    /// Paths for a profile directory.
    public static func profile(_ root: URL) -> Paths {
        Paths(appSupport: root,
              caches: root.appending(path: "Caches", directoryHint: .isDirectory),
              logs: root.appending(path: "Logs", directoryHint: .isDirectory),
              isProfile: true)
    }

    /// The user's real locations.
    public static func user(fileManager: FileManager = .default) -> Paths {
        let library = fileManager.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
        return Paths(appSupport: library.appending(path: "Application Support/sudamp", directoryHint: .isDirectory),
                     caches: library.appending(path: "Caches/sudamp", directoryHint: .isDirectory),
                     logs: library.appending(path: "Logs/sudamp", directoryHint: .isDirectory),
                     isProfile: false)
    }

    /// Resolves from command-line arguments (`--profile <dir>` or `--profile=<dir>`) then `SUDAMP_HOME`, else user.
    public static func resolve(arguments: [String] = CommandLine.arguments,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        if let dir = profileArgument(arguments) ?? environment["SUDAMP_HOME"], !dir.isEmpty {
            return .profile(URL(filePath: (dir as NSString).expandingTildeInPath, directoryHint: .isDirectory))
        }
        return .user()
    }

    static func profileArgument(_ arguments: [String]) -> String? {
        for (i, a) in arguments.enumerated() {
            if a == "--profile", i + 1 < arguments.count { return arguments[i + 1] }
            if a.hasPrefix("--profile=") { return String(a.dropFirst("--profile=".count)) }
        }
        return nil
    }

    // MARK: Well-known locations (DESIGN §10)
    public var sessionFile: URL { appSupport.appending(path: "session.json") }
    public var libraryFile: URL { appSupport.appending(path: "library.json") }
    public var instanceLock: URL { appSupport.appending(path: "instance.lock") }
    /// Kept at the profile root to stay within the 104-byte Unix socket path limit.
    public var instanceSocket: URL { appSupport.appending(path: "instance.sock") }
    public var debugState: URL { appSupport.appending(path: "debug/state.json") }
    public var engines: URL { appSupport.appending(path: "engines", directoryHint: .isDirectory) }
    public var engineHome: URL { appSupport.appending(path: "engine-home", directoryHint: .isDirectory) }
    public var feedDirectory: URL { appSupport.appending(path: "feed", directoryHint: .isDirectory) }
    public var skins: URL { appSupport.appending(path: "Skins", directoryHint: .isDirectory) }
    public var metricsFile: URL { logs.appending(path: "metrics.jsonl") }

    /// Creates the top-level directories if missing.
    public func createDirectories(fileManager: FileManager = .default) throws {
        for dir in [appSupport, caches, logs] {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
