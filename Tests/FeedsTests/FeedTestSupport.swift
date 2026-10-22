// SPDX-License-Identifier: GPL-3.0-or-later
import Catalog
import Core
import Foundation
@testable import Feeds

let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let repoFeed = repoRoot.appending(path: "catalog/feed.json")

func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "feeds-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func write(_ json: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(json.utf8).write(to: url)
}

/// A minimal valid document: one genre, one radio station, an optional `expiresAt` and engine section.
func doc(revision: Int, expires: String? = nil, minApp: String? = nil, engine: String? = nil) -> String {
    let e = expires.map { #""expiresAt":"\#($0)","# } ?? ""
    let engineJSON = engine ?? minApp.map { #"{"minAppVersion":"\#($0)"}"# }
    let m = engineJSON.map { #","engine":\#($0)"# } ?? ""
    return #"{"schema":1,"revision":\#(revision),"generatedAt":"2026-10-22T10:00:00Z",\#(e)"catalog":{"genres":[{"id":"techno","name":"Techno"}],"streams":[{"id":"radio:t","source":"radio","ref":"https://t.example.com/s","title":"T","creator":"C","genres":["techno"],"homepage":"https://example.com/"}]}\#(m)}"#
}

/// The committed test key (`Fixtures/keys/test-ed25519.key`), read the way `catalog-tool sign` reads it.
let testSigningKey: FeedSigningKey = {
    let text = (try? String(contentsOf: repoRoot.appending(path: "Fixtures/keys/test-ed25519.key"), encoding: .utf8)) ?? ""
    return FeedSigningKey(text: text) ?? FeedSigningKey()
}()

let testTrust = FeedTrust(keys: [testSigningKey.publicKey].compactMap { $0 })

/// 2026-10-22T12:00:00Z.
let launchDate = Date(timeIntervalSince1970: 1_792_670_400)

func bundledFeed(revision: Int = 2, expires: String? = "2027-04-22T00:00:00Z", engine: String? = nil) throws -> LoadedFeed {
    try BundledFeed.load(data: Data(doc(revision: revision, expires: expires, engine: engine).utf8),
                         url: URL(filePath: "/bundle/feed.json"), origin: .bundled)
}

/// A body and its detached signature.
func signed(_ json: String, with key: FeedSigningKey = testSigningKey) throws -> (body: Data, signature: Data) {
    let body = Data(json.utf8)
    return (body, try key.sign(body))
}

/// A service over a stub host with a cache in `dir`, the test key trusted and a fake clock.
func makeService(server: StubFeedServer, dir: URL, bundled: LoadedFeed, time: FakeTimeSource,
                 appVersion: String = "0.1.0", metrics: MetricsLog? = nil, timeout: TimeInterval = 5,
                 sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) throws -> FeedService {
    let config = FeedServiceConfiguration(appVersion: appVersion, trust: testTrust,
                                          cache: FeedCache(directory: dir.appending(path: "feed", directoryHint: .isDirectory)))
    if let sleeper {
        return FeedService(bundled: bundled, configuration: config, client: try server.client(timeout: timeout),
                           time: time, metrics: metrics, sleeper: sleeper)
    }
    return FeedService(bundled: bundled, configuration: config, client: try server.client(timeout: timeout), time: time,
                       metrics: metrics)
}

/// Lines of a metrics log with the given event name.
func metricEvents(_ log: MetricsLog, _ event: String) throws -> [[String: Any]] {
    let text = try String(contentsOf: log.url, encoding: .utf8)
    return text.split(separator: "\n").compactMap { line in
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }.filter { ($0["event"] as? String) == event }
}
