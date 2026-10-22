// SPDX-License-Identifier: GPL-3.0-or-later
import Audio
import Core
import Foundation
import MPV
import Synchronization

/// mpv + the output graph wired as the app will be (DESIGN §5), for headless tools. AUDIO SAFETY: the mixer
/// volume is 0 *and* the render bridge zeroes its output after measuring it, so nothing reaches the device.
final class EngineHarness: Sendable {
    let audio: AudioEngine
    let mpv: MPVClient
    let events: EventLog

    var bridge: RenderBridge { audio.bridge }

    init(probeCapacity: Int = 0, overrides: [MPVOption] = [], logLevel: String = "warn", mpvLog: URL? = nil) throws {
        audio = try AudioEngine(volume: 0)
        audio.bridge.setOutputMuted(true)
        if probeCapacity > 0 { audio.bridge.enableProbe(capacity: probeCapacity) }
        let events = try EventLog(logFile: mpvLog)
        self.events = events
        mpv = try MPVClient(options: MPVOptions.merged(overrides: overrides), logLevel: logLevel,
                            eventHandler: { events.record($0) })
        let mpv = self.mpv
        audio.setSourceControl(SourceControl(pause: { _ = try? mpv.setPause(true) },
                                             resume: { _ = try? mpv.setPause(false) }))
    }

    func start() throws { try audio.start() }

    /// DESIGN §5.2 order: stop the audio engine, then the mpv shutdown sequence.
    func shutdown() {
        audio.stop()
        mpv.shutdown()
        events.close()
    }

    /// Host pause first (silence behind the 5 ms ramp), then mpv once the ramp has rendered (DESIGN §5.2).
    func pause() throws {
        audio.hostPauseAndWaitForRamp()
        try mpv.setPause(true)
    }

    func resume(fadeSeconds: Double = 0) throws {
        try mpv.setPause(false)
        audio.hostResume(fadeSeconds: fadeSeconds)
    }

    /// The fixed-path fixture, generated on demand (fixtures are never committed).
    static func fixture(_ path: String?) throws -> URL {
        let url = URL(filePath: path ?? RampFixture.defaultRelativePath)
        if path == nil { try RampFixture.ensure(at: url) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("fixture not found: \(url.path)") }
        return url
    }
}

/// Timestamped mpv events, plus an optional raw log file (for the E1 script/option checks).
final class EventLog: Sendable {
    struct Entry: Sendable {
        var nanos: UInt64
        var event: MPVEvent
    }

    private let entries = Mutex<[Entry]>([])
    private let file: Mutex<FileHandle?>

    init(logFile: URL?) throws {
        if let logFile {
            try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            file = Mutex(try FileHandle(forWritingTo: logFile))
        } else {
            file = Mutex(nil)
        }
    }

    func record(_ event: MPVEvent) {
        let now = monotonicNanos()
        if case .log(let m) = event {
            file.withLock { fh in
                try? fh?.write(contentsOf: Data("[\(m.level)] \(m.prefix): \(m.text)\n".utf8))
            }
        }
        entries.withLock { $0.append(Entry(nanos: now, event: event)) }
    }

    func close() { file.withLock { try? $0?.close(); $0 = nil } }

    var all: [Entry] { entries.withLock { $0 } }

    var logMessages: [MPVLogMessage] {
        all.compactMap { if case .log(let m) = $0.event { return m } else { return nil } }
    }

    /// error/fatal log lines and failed end-file events, for reports.
    var errors: [String] {
        all.compactMap { entry -> String? in
            switch entry.event {
            case .log(let m) where m.level == "error" || m.level == "fatal": return "\(m.prefix): \(m.text)"
            case .endFile(let e) where e.reason == .error: return "end-file error: \(e.errorDescription ?? "?")"
            default: return nil
            }
        }
    }

    /// Built-in Lua scripts mpv started (must be empty, E1). Needs log level "debug" to see the loader lines.
    var scriptsLoaded: [String] {
        let names = ["osc", "ytdl_hook", "stats", "console", "auto_profiles", "select", "positioning", "commands",
                     "context_menu"]
        var out = Set<String>()
        for m in logMessages {
            if m.text.contains("Loading lua script") || m.text.contains("Loading javascript script") { out.insert(m.text) }
            if names.contains(m.prefix) { out.insert("[\(m.prefix)] client active") }
        }
        return out.sorted()
    }

    /// FFmpeg options mpv could not apply (`Could not set AVOption k='v'`, logged at -v).
    var unsetAVOptions: [String] {
        logMessages.filter { $0.text.hasPrefix("Could not set AVOption") }.map(\.text)
    }
}

struct ToolError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
