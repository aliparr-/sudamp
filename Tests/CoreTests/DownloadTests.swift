// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization
import Testing
@testable import Core

/// Serves registered bodies offline, honouring `Range`, and can cut a transfer short to simulate a dropped link.
final class StubHTTPProtocol: URLProtocol {
    struct Route: Sendable {
        var body: Data
        var status: Int = 200
        var headers: [String: String] = [:]
        var honoursRange = true
        /// Stop with a network error after this many body bytes (once), to exercise resume.
        var failAfter: Int?
    }

    struct Hit: Sendable {
        var url: String
        var method: String
        var range: String?
        var userAgent: String?
    }

    static let routes = Mutex<[String: Route]>([:])
    static let hits = Mutex<[Hit]>([])

    static func register(_ url: String, _ route: Route) { routes.withLock { $0[url] = route } }
    static func hits(for url: String) -> [Hit] { hits.withLock { $0.filter { $0.url == url } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let key = url.absoluteString
        let range = request.value(forHTTPHeaderField: "Range")
        Self.hits.withLock {
            $0.append(Hit(url: key, method: request.httpMethod ?? "GET", range: range,
                          userAgent: request.value(forHTTPHeaderField: "User-Agent")))
        }
        guard var route = Self.routes.withLock({ $0[key] }) else {
            client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1",
                                                                 headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
            return
        }
        var status = route.status
        var headers = route.headers
        var body = route.body
        if route.honoursRange, status == 200, let range, range.hasPrefix("bytes="),
           let start = Int(range.dropFirst(6).dropLast(range.hasSuffix("-") ? 1 : 0)) {
            if start >= route.body.count {
                status = 416
                headers["Content-Range"] = "bytes */\(route.body.count)"
                body = Data()
            } else {
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(route.body.count - 1)/\(route.body.count)"
                body = route.body.subdata(in: start..<route.body.count)
            }
        }
        headers["Content-Length"] = String(body.count)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let cut = route.failAfter, cut < body.count {
            // Deliver in chunks and let the session drain them before the link "drops", as a real socket would.
            var offset = 0
            while offset < cut {
                let n = min(16_384, cut - offset)
                client.urlProtocol(self, didLoad: body.subdata(in: offset..<offset + n))
                offset += n
            }
            usleep(200_000)
            route.failAfter = nil
            Self.register(key, route)
            client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if !body.isEmpty, request.httpMethod != "HEAD" { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }

    static func downloader() -> HTTPDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHTTPProtocol.self]
        return HTTPDownloader(configuration: config, userAgent: "sudamp-test")
    }
}

@Suite(.serialized) struct DownloadTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)/file.partial")
    }

    private func payload(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    @Test func fullDownloadWritesTheBody() async throws {
        let url = "https://stub.test/full-\(UUID().uuidString)"
        let body = payload(300_000)
        StubHTTPProtocol.register(url, .init(body: body))
        let file = tempFile()
        let outcome = try await StubHTTPProtocol.downloader().download(URL(string: url)!, to: file)
        #expect(try Data(contentsOf: file) == body)
        #expect(outcome.httpStatus == 200)
        #expect(outcome.resumedFrom == 0)
        #expect(!outcome.sentRange)
        #expect(StubHTTPProtocol.hits(for: url).first?.userAgent == "sudamp-test")
    }

    @Test func droppedTransferResumesWithARangeRequest() async throws {
        let url = "https://stub.test/resume-\(UUID().uuidString)"
        let body = payload(500_000)
        StubHTTPProtocol.register(url, .init(body: body, failAfter: 123_456))
        let file = tempFile()
        let downloader = StubHTTPProtocol.downloader()
        await #expect(throws: (any Error).self) { try await downloader.download(URL(string: url)!, to: file) }
        let kept = try Data(contentsOf: file)
        #expect(kept.count == 123_456)
        let outcome = try await downloader.download(URL(string: url)!, to: file)
        #expect(outcome.httpStatus == 206)
        #expect(outcome.sentRange)
        #expect(outcome.resumedFrom == 123_456)
        #expect(outcome.bytesReceived == Int64(body.count - 123_456))
        #expect(try Data(contentsOf: file) == body)
        #expect(StubHTTPProtocol.hits(for: url).map(\.range) == [nil, "bytes=123456-"])
    }

    @Test func serverIgnoringRangeRestartsFromZero() async throws {
        let url = "https://stub.test/norange-\(UUID().uuidString)"
        let body = payload(10_000)
        StubHTTPProtocol.register(url, .init(body: body, honoursRange: false))
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 4_000).write(to: file)
        let outcome = try await StubHTTPProtocol.downloader().download(URL(string: url)!, to: file)
        #expect(outcome.httpStatus == 200)
        #expect(outcome.resumedFrom == 0)
        #expect(try Data(contentsOf: file) == body)
    }

    @Test func alreadyCompleteFileIsAccepted() async throws {
        let url = "https://stub.test/done-\(UUID().uuidString)"
        let body = payload(2_048)
        StubHTTPProtocol.register(url, .init(body: body))
        let file = tempFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: file)
        let outcome = try await StubHTTPProtocol.downloader().download(URL(string: url)!, to: file)
        #expect(outcome.httpStatus == 416)
        #expect(outcome.bytesOnDisk == 2_048)
        #expect(try Data(contentsOf: file) == body)
    }

    @Test func httpErrorsThrow() async throws {
        let url = "https://stub.test/missing-\(UUID().uuidString)"
        await #expect(throws: DownloadError.httpStatus(404, url: url)) {
            try await StubHTTPProtocol.downloader().download(URL(string: url)!, to: tempFile())
        }
        await #expect(throws: DownloadError.httpStatus(404, url: url)) {
            try await StubHTTPProtocol.downloader().data(from: URL(string: url)!)
        }
        #expect(try await StubHTTPProtocol.downloader().optionalData(from: URL(string: url)!) == nil)
    }

    @Test func redirectLocationIsReadWithoutFollowing() async throws {
        let url = "https://stub.test/releases/latest-\(UUID().uuidString)"
        StubHTTPProtocol.register(url, .init(body: Data(), status: 302,
                                             headers: ["Location": "https://stub.test/releases/tag/2026.10.21"]))
        let location = try await StubHTTPProtocol.downloader().redirectLocation(of: URL(string: url)!)
        #expect(location?.absoluteString == "https://stub.test/releases/tag/2026.10.21")
    }

    @Test func progressIsReported() async throws {
        let url = "https://stub.test/progress-\(UUID().uuidString)"
        StubHTTPProtocol.register(url, .init(body: payload(70_000)))
        let seen = Mutex<[Int64]>([])
        _ = try await StubHTTPProtocol.downloader().download(URL(string: url)!, to: tempFile()) { onDisk, expected in
            #expect(expected == 70_000)
            seen.withLock { $0.append(onDisk) }
        }
        #expect(seen.withLock { $0.last } == 70_000)
    }

    @Test func contentRangeParsing() {
        #expect(ContentRange("bytes 100-199/1000") == ContentRange("bytes 100-199/1000"))
        #expect(ContentRange("bytes 100-199/1000")?.start == 100)
        #expect(ContentRange("bytes 100-199/1000")?.total == 1000)
        #expect(ContentRange("bytes 100-199/*")?.total == nil)
        #expect(ContentRange("bytes 5-1/10") == nil)
        #expect(ContentRange("items 1-2/3") == nil)
        #expect(ContentRange.unsatisfiedTotal("bytes */4096") == 4096)
        #expect(ContentRange.unsatisfiedTotal("bytes 0-1/2") == nil)
    }
}

@Suite struct FileDigestTests {
    @Test func knownVectors() throws {
        #expect(FileDigest.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(FileDigest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func fileDigestMatchesInMemoryDigestAcrossChunks() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "digest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<2_500_001).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: url)
        #expect(try FileDigest.sha256(of: url, chunkSize: 1 << 20) == FileDigest.sha256(data))
        #expect(try FileDigest.sha256(of: url, chunkSize: 7) == FileDigest.sha256(data))
    }

    @Test func hexValidation() {
        #expect(FileDigest.isSHA256Hex(String(repeating: "a", count: 64)))
        #expect(!FileDigest.isSHA256Hex(String(repeating: "A", count: 64)))
        #expect(!FileDigest.isSHA256Hex(String(repeating: "a", count: 63)))
        #expect(!FileDigest.isSHA256Hex(String(repeating: "g", count: 64)))
    }

    @Test func diskSpaceWalksUpToAnExistingAncestor() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no/such/dir/\(UUID().uuidString)")
        #expect((DiskSpace.available(at: missing) ?? 0) > 0)
    }
}
