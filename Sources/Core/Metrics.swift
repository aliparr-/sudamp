import Foundation
import Synchronization

/// Append-only local metrics log (`<logs>/metrics.jsonl`) that acceptance tests read with `jq` (DESIGN §7.3).
/// Never uploaded. Each line: `{"ts": <unix seconds>, "event": "...", ...fields}`.
public final class MetricsLog: Sendable {
    public let url: URL
    private let handle: Mutex<FileHandle?>
    private let time: any TimeSource

    public init(url: URL, time: any TimeSource = SystemTimeSource()) {
        self.url = url
        self.time = time
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let fh = try? FileHandle(forWritingTo: url)
        _ = try? fh?.seekToEnd()
        handle = Mutex(fh)
    }

    /// Records one event. Values must be JSON-representable (String, numbers, Bool, arrays/dicts of those, NSNull).
    public func record(_ event: String, _ fields: [String: any Sendable] = [:]) {
        var object: [String: Any] = ["ts": time.now.timeIntervalSince1970, "event": event]
        for (k, v) in fields { object[k] = v }
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        handle.withLock { fh in
            try? fh?.write(contentsOf: data)
        }
    }
}
