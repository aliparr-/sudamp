// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization

/// Result of `HTTPDownloader.download`.
public struct DownloadOutcome: Sendable, Equatable {
    /// Size of the file on disk afterwards.
    public var bytesOnDisk: Int64
    /// Bytes that were already on disk and kept (0 when the server ignored the Range request or none was sent).
    public var resumedFrom: Int64
    /// Bytes received in this call.
    public var bytesReceived: Int64
    /// Final HTTP status (206 for a resumed transfer, 200 for a full one, 416 when the file was already complete).
    public var httpStatus: Int
    /// Whether a `Range` header was sent.
    public var sentRange: Bool

    public init(bytesOnDisk: Int64, resumedFrom: Int64, bytesReceived: Int64, httpStatus: Int, sentRange: Bool) {
        self.bytesOnDisk = bytesOnDisk
        self.resumedFrom = resumedFrom
        self.bytesReceived = bytesReceived
        self.httpStatus = httpStatus
        self.sentRange = sentRange
    }
}

public enum DownloadError: Error, Sendable, Equatable {
    case httpStatus(Int, url: String)
    /// A 206 whose Content-Range doesn't start where the partial file ends.
    case unexpectedRange(String)
    case io(String)
    case notHTTP
}

/// Minimal URLSession wrapper for the engine download (DESIGN §6.1): small fetches, redirect inspection and a
/// resumable streaming download that appends to a `.partial` file with an HTTP `Range` request.
public final class HTTPDownloader: Sendable {
    public let session: URLSession
    public let userAgent: String

    /// `configuration` is copied; tests pass one with stub `protocolClasses`. No cookies, no cache, no credentials.
    public init(configuration: URLSessionConfiguration = .ephemeral,
                userAgent: String = "sudamp/\(BuildInfo.version)") {
        let config = configuration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        self.userAgent = userAgent
    }

    deinit { session.finishTasksAndInvalidate() }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    /// GET into memory; non-2xx statuses throw.
    public func data(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(url))
        guard let http = response as? HTTPURLResponse else { throw DownloadError.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode, url: url.absoluteString)
        }
        return data
    }

    /// GET that returns nil on 404 (an optional asset such as `_update_spec`).
    public func optionalData(from url: URL) async throws -> Data? {
        do { return try await data(from: url) } catch DownloadError.httpStatus(404, _) { return nil }
    }

    /// The `Location` of a redirect, without following it (e.g. `releases/latest` → `releases/tag/<ver>`).
    public func redirectLocation(of url: URL) async throws -> URL? {
        var r = request(url)
        r.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: r, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw DownloadError.notHTTP }
        guard (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location") else { return nil }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }

    /// Streams `url` into `file`. If `file` already has bytes, asks for the rest with `Range: bytes=<size>-` and
    /// appends on 206; a 200 restarts from zero; a 416 whose `Content-Range: bytes */<n>` equals the size on disk
    /// means the file is already complete. Cancellation stops the transfer and keeps what was written.
    public func download(_ url: URL, to file: URL,
                         progress: (@Sendable (_ onDisk: Int64, _ expected: Int64?) -> Void)? = nil)
        async throws -> DownloadOutcome {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        let existing = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0

        var r = request(url)
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if existing > 0 { r.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let delegate = try StreamToFile(file: file, existing: existing, progress: progress)
        let task = session.dataTask(with: r)
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// Refuses redirects so the 3xx response itself is returned.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Per-task delegate that appends response bytes to a file as they arrive.
private final class StreamToFile: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var handle: FileHandle?
        var continuation: CheckedContinuation<DownloadOutcome, any Error>?
        var outcome: DownloadOutcome
        var expected: Int64?
        var failure: (any Error)?
    }

    private let file: URL
    private let progress: (@Sendable (Int64, Int64?) -> Void)?
    private let state: Mutex<State>

    init(file: URL, existing: Int64, progress: (@Sendable (Int64, Int64?) -> Void)?) throws {
        self.file = file
        self.progress = progress
        state = Mutex(State(outcome: DownloadOutcome(bytesOnDisk: existing, resumedFrom: 0, bytesReceived: 0,
                                                     httpStatus: 0, sentRange: existing > 0)))
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<DownloadOutcome, any Error>) {
        state.withLock { $0.continuation = continuation }
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let disposition: URLSession.ResponseDisposition = state.withLock { s in
            guard let http = response as? HTTPURLResponse else {
                s.failure = DownloadError.notHTTP
                return .cancel
            }
            s.outcome.httpStatus = http.statusCode
            let onDisk = s.outcome.bytesOnDisk
            do {
                switch http.statusCode {
                case 206:
                    let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                    guard let parsed = ContentRange(range), parsed.start == onDisk else {
                        throw DownloadError.unexpectedRange(range)
                    }
                    s.expected = parsed.total
                    s.outcome.resumedFrom = onDisk
                    let h = try FileHandle(forWritingTo: file)
                    try h.seekToEnd()
                    s.handle = h
                case 200:
                    s.expected = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
                    let h = try FileHandle(forWritingTo: file)
                    try h.truncate(atOffset: 0)
                    s.handle = h
                    s.outcome.bytesOnDisk = 0
                    s.outcome.resumedFrom = 0
                case 416:
                    // Already complete only if the server's total equals what we hold.
                    let range = http.value(forHTTPHeaderField: "Content-Range") ?? ""
                    if let total = ContentRange.unsatisfiedTotal(range), total == onDisk {
                        s.outcome.resumedFrom = onDisk
                        return .cancel
                    }
                    try? FileManager.default.removeItem(at: file)
                    throw DownloadError.httpStatus(416, url: response.url?.absoluteString ?? "")
                default:
                    throw DownloadError.httpStatus(http.statusCode, url: response.url?.absoluteString ?? "")
                }
                return .allow
            } catch {
                s.failure = error
                return .cancel
            }
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: (Int64, Int64?)? = state.withLock { s in
            guard let handle = s.handle, s.failure == nil else { return nil }
            do {
                try handle.write(contentsOf: data)
                s.outcome.bytesOnDisk += Int64(data.count)
                s.outcome.bytesReceived += Int64(data.count)
                return (s.outcome.bytesOnDisk, s.expected)
            } catch {
                s.failure = DownloadError.io("\(error)")
                dataTask.cancel()
                return nil
            }
        }
        if let report { progress?(report.0, report.1) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result): (CheckedContinuation<DownloadOutcome, any Error>?, Result<DownloadOutcome, any Error>) =
            state.withLock { s in
                try? s.handle?.synchronize()
                try? s.handle?.close()
                s.handle = nil
                let c = s.continuation
                s.continuation = nil
                if let failure = s.failure { return (c, .failure(failure)) }
                // Our own `.cancel` for an already-complete 416 is a success, not an error.
                if s.outcome.httpStatus == 416 { return (c, .success(s.outcome)) }
                if let error {
                    let cancelled = (error as? URLError)?.code == .cancelled
                    return (c, .failure(cancelled ? CancellationError() : error))
                }
                if let expected = s.expected, expected != s.outcome.bytesOnDisk {
                    return (c, .failure(DownloadError.io("short read: \(s.outcome.bytesOnDisk) of \(expected) bytes")))
                }
                return (c, .success(s.outcome))
            }
        continuation?.resume(with: result)
    }
}

/// `Content-Range: bytes <start>-<end>/<total|*>` (RFC 9110 §14.4).
struct ContentRange: Equatable {
    var start: Int64
    var end: Int64
    var total: Int64?

    init?(_ header: String) {
        let s = header.trimmingCharacters(in: .whitespaces)
        guard s.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = s.dropFirst(6)
        let halves = spec.split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let a = Int64(bounds[0]), let b = Int64(bounds[1]), a <= b else { return nil }
        start = a
        end = b
        total = halves[1] == "*" ? nil : Int64(halves[1])
    }

    /// The `<n>` of `bytes */<n>`, sent with 416.
    static func unsatisfiedTotal(_ header: String) -> Int64? {
        let s = header.trimmingCharacters(in: .whitespaces)
        guard s.lowercased().hasPrefix("bytes */") else { return nil }
        return Int64(s.dropFirst(8))
    }
}

/// Free space for the volume holding `url` (DESIGN §6.1: check ~180 MB before downloading the engine).
public enum DiskSpace {
    public static func available(at url: URL) -> Int64? {
        var probe = url
        // Walk up to an existing ancestor: the engines directory may not exist yet.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
