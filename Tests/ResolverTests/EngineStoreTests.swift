// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Darwin
import Foundation
import Synchronization
import Testing
@testable import Resolver

/// Builds tiny fake engine releases (a shell script that prints its version, plus an `_internal/` file) zipped
/// with `ditto`, and serves them like GitHub would — offline.
final class FakeReleases: EngineReleaseSource {
    struct Release {
        var zip: Data
        var sums: String
    }

    let name: String
    let latest: String
    let recent: [String]
    let spec: String?
    private let releases: [String: Release]
    let downloads = Mutex<[String]>([])

    init(latest: String, versions: [String], spec: String? = nil, corrupt: Set<String> = [],
         printedVersion: [String: String] = [:], name: String = "yt-dlp/yt-dlp") throws {
        self.name = name
        self.latest = latest
        recent = versions
        self.spec = spec
        var releases: [String: Release] = [:]
        for v in versions {
            let zip = try Self.makeZip(printing: printedVersion[v] ?? v)
            let hash = corrupt.contains(v) ? String(repeating: "0", count: 64) : FileDigest.sha256(zip)
            releases[v] = Release(zip: zip, sums: "\(hash)  yt-dlp_macos.zip\n\(String(repeating: "1", count: 64))  yt-dlp_macos\n")
        }
        self.releases = releases
    }

    static func makeZip(printing version: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appending(path: "fake-engine-\(UUID().uuidString)")
        let tree = dir.appending(path: "tree")
        try FileManager.default.createDirectory(at: tree.appending(path: "_internal"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exe = tree.appending(path: "yt-dlp_macos")
        try "#!/bin/sh\necho \(version)\n".write(to: exe, atomically: true, encoding: .utf8)
        chmod(exe.path, 0o755)
        try Data("python stand-in".utf8).write(to: tree.appending(path: "_internal/lib.bin"))
        let zip = dir.appending(path: "e.zip")
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", tree.path, zip.path]
        try p.run()
        p.waitUntilExit()
        return try Data(contentsOf: zip)
    }

    func latestVersion() async throws -> String { latest }
    func recentVersions() async throws -> [String] { recent }
    func updateSpec() async throws -> String? { spec }
    func checksums(version: String) async throws -> String {
        guard let r = releases[version] else { throw DownloadError.httpStatus(404, url: version) }
        return r.sums
    }

    func download(asset: String, version: String, to file: URL,
                  progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> DownloadOutcome {
        guard let r = releases[version] else { throw DownloadError.httpStatus(404, url: version) }
        downloads.withLock { $0.append(version) }
        let have = (try? Data(contentsOf: file)) ?? Data()
        let resumed = have.count > 0 && have.count <= r.zip.count && r.zip.prefix(have.count) == have
        let body = resumed ? have + r.zip.dropFirst(have.count) : r.zip
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: file)
        progress?(Int64(body.count), Int64(r.zip.count))
        return DownloadOutcome(bytesOnDisk: Int64(body.count), resumedFrom: resumed ? Int64(have.count) : 0,
                               bytesReceived: Int64(body.count - (resumed ? have.count : 0)),
                               httpStatus: resumed ? 206 : 200, sentRange: have.count > 0)
    }
}

@Suite struct EngineStoreTests {
    let profile = FileManager.default.temporaryDirectory.appending(path: "engine-store-\(UUID().uuidString)")
    var layout: EngineLayout { EngineLayout(paths: .profile(profile)) }

    @Test func firstInstallRecordsTreeAndSwitchesCurrent() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21", "2026.08.19"])
        let store = EngineStore(layout: layout, releases: releases, time: FakeTimeSource())
        let report = try await store.install(config: EngineInstallPolicy())

        #expect(report.version == "2026.10.21")
        #expect(report.reason == .latest)
        #expect(report.verifiedAgainst == "upstream")
        #expect(report.upstreamMatch)
        #expect(report.quarantined.isEmpty)
        #expect(report.files == 2)
        #expect(report.smoke?.output == "2026.10.21")
        #expect(report.smoke?.warmMs.count == 3)
        let current = try #require(await store.current())
        #expect(current.version == "2026.10.21")
        #expect(current.previous == nil)
        #expect(FileManager.default.isExecutableFile(atPath: current.executableURL(in: layout).path))
        #expect(!FileManager.default.fileExists(atPath: layout.partialDirectory("2026.10.21").path))
        let tree = try JSONDecoder().decode(EngineTree.self, from: Data(contentsOf:
            layout.versionDirectory("2026.10.21").appending(path: "tree.json")))
        #expect(tree.entries.map(\.path) == ["_internal/lib.bin", "yt-dlp_macos"])
        #expect(tree.entries.last?.mode == "0755")
        #expect(try await store.verifyTree().ok)
    }

    @Test func blockedLatestInstallsThePinVerifiedAgainstThePin() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21", "2026.08.19"])
        let pinSHA = SHA256Sums(parsing: try await releases.checksums(version: "2026.08.19"))["yt-dlp_macos.zip"]!
        let store = EngineStore(layout: layout, releases: releases)
        let report = try await store.install(config: EngineInstallPolicy(pin: .init(version: "2026.08.19", sha256: pinSHA),
                                                                  block: ["2026.10.21"]))
        #expect(report.version == "2026.08.19")
        #expect(report.reason == .pin)
        #expect(report.verifiedAgainst == "pin")
        #expect(releases.downloads.withLock { $0 } == ["2026.08.19"])
    }

    @Test func wrongPinHashRefusesTheZipAndDeletesIt() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let store = EngineStore(layout: layout, releases: releases)
        let bad = String(repeating: "c", count: 64)
        await #expect(throws: EngineStoreError.self) {
            try await store.install(config: EngineInstallPolicy(pin: .init(version: "2026.10.21", sha256: bad)))
        }
        #expect(await store.current() == nil)
        let zip = layout.partialDirectory("2026.10.21").appending(path: "yt-dlp_macos.zip")
        #expect(!FileManager.default.fileExists(atPath: zip.path))
    }

    @Test func upstreamChecksumMismatchFails() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"], corrupt: ["2026.10.21"])
        let store = EngineStore(layout: layout, releases: releases)
        do {
            _ = try await store.install(config: EngineInstallPolicy())
            Issue.record("install should fail")
        } catch let EngineStoreError.checksumMismatch(expected, _) {
            #expect(expected == String(repeating: "0", count: 64))
        }
    }

    @Test func insufficientSpaceStopsBeforeDownloading() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let store = EngineStore(layout: layout, releases: releases, freeSpace: { _ in 50_000_000 })
        await #expect(throws: EngineStoreError.insufficientSpace(available: 50_000_000, required: 180_000_000)) {
            try await store.install(config: EngineInstallPolicy())
        }
        #expect(releases.downloads.withLock { $0 }.isEmpty)
    }

    @Test func partialDownloadIsResumed() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        // Plant the first bytes of the real zip as an interrupted download.
        let partial = layout.partialDirectory("2026.10.21")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let full = try await releases.download(asset: "yt-dlp_macos.zip", version: "2026.10.21",
                                               to: profile.appending(path: "scratch.zip"), progress: nil)
        let bytes = try Data(contentsOf: profile.appending(path: "scratch.zip"))
        try bytes.prefix(Int(full.bytesOnDisk / 2)).write(to: partial.appending(path: "yt-dlp_macos.zip"))
        let report = try await EngineStore(layout: layout, releases: releases).install(config: EngineInstallPolicy())
        #expect(report.download?.sentRange == true)
        #expect(report.download?.resumedFrom == full.bytesOnDisk / 2)
        #expect(report.upstreamMatch)
    }

    @Test func updateKeepsPreviousAndPrunesOlder() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        for (latest, previous) in [("2026.07.04", nil), ("2026.08.19", "2026.07.04"), ("2026.10.21", "2026.08.19")] {
            let releases = try FakeReleases(latest: latest, versions: [latest])
            let report = try await EngineStore(layout: layout, releases: releases).install(config: EngineInstallPolicy())
            #expect(report.previous == previous)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: layout.enginesRoot.path).sorted()
        #expect(names == ["2026.08.19", "2026.10.21", "current.json"])
    }

    @Test func reinstallOfCurrentIsANoOpUntilTheTreeIsTampered() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let store = EngineStore(layout: layout, releases: releases)
        _ = try await store.install(config: EngineInstallPolicy())
        #expect(try await store.install(config: EngineInstallPolicy()).alreadyInstalled)

        let lib = layout.versionDirectory("2026.10.21").appending(path: "_internal/lib.bin")
        try Data("tampered".utf8).write(to: lib)
        let check = try await store.verifyTree()
        #expect(check.modified == ["_internal/lib.bin"])
        let again = try await store.install(config: EngineInstallPolicy())
        #expect(!again.alreadyInstalled)
        #expect(try await store.verifyTree().ok)
        #expect(releases.downloads.withLock { $0.count } == 2)
    }

    @Test func smokeTestRejectsAnEngineReportingTheWrongVersion() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"],
                                        printedVersion: ["2026.10.21": "1999.01.01"])
        await #expect(throws: EngineStoreError.self) {
            try await EngineStore(layout: layout, releases: releases).install(config: EngineInstallPolicy())
        }
        #expect(await EngineStore(layout: layout, releases: releases).current() == nil)
    }

    @Test func chooseHonoursUpdateSpecLocks() async throws {
        let spec = "lockV2 yt-dlp/yt-dlp 2025.08.11 darwin_dir .+\n"
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21", "2025.08.11"], spec: spec)
        let (choice, info) = try await EngineStore(layout: layout, releases: releases).choose(config: EngineInstallPolicy())
        #expect(choice == EngineChoice(version: "2025.08.11", reason: .updateSpecLock))
        #expect(info.present)
        #expect(info.lockedTag == "2025.08.11")
    }
}

@Suite struct EngineTreeTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tree-\(UUID().uuidString)")

    private func make() throws {
        try FileManager.default.createDirectory(at: root.appending(path: "_internal/sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appending(path: "yt-dlp_macos"))
        chmod(root.appending(path: "yt-dlp_macos").path, 0o755)
        try Data("bb".utf8).write(to: root.appending(path: "_internal/sub/b.so"))
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "_internal/link").path,
                                                   withDestinationPath: "sub/b.so")
    }

    @Test func scanRecordsFilesModesAndLinks() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make()
        let tree = try EngineTree.scan(root: root, version: "2026.10.21")
        #expect(tree.entries.map(\.path) == ["_internal/link", "_internal/sub/b.so", "yt-dlp_macos"])
        #expect(tree.entries[0].link == "sub/b.so")
        #expect(tree.entries[0].sha256 == nil)
        #expect(tree.entries[1].sha256 == FileDigest.sha256(Data("bb".utf8)))
        #expect(tree.entries[2].mode == "0755")
        #expect(tree.totalBytes == 3)
        #expect(try tree.verify(root: root).ok)
    }

    @Test func verifyFindsEveryKindOfDrift() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make()
        let tree = try EngineTree.scan(root: root, version: "2026.10.21")
        try Data("BB".utf8).write(to: root.appending(path: "_internal/sub/b.so"))
        chmod(root.appending(path: "yt-dlp_macos").path, 0o777)
        try FileManager.default.removeItem(at: root.appending(path: "_internal/link"))
        // A plugin planted next to the executable must be noticed.
        try FileManager.default.createDirectory(at: root.appending(path: "yt-dlp-plugins/x/yt_dlp_plugins/extractor"),
                                                withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "yt-dlp-plugins/x/yt_dlp_plugins/extractor/evil.py"))
        try Data("{}".utf8).write(to: root.appending(path: "tree.json"))  // the manifest itself is not data
        let v = try tree.verify(root: root)
        #expect(!v.ok)
        #expect(v.modified == ["_internal/sub/b.so"])
        #expect(v.modeChanged == ["yt-dlp_macos"])
        #expect(v.missing == ["_internal/link"])
        #expect(v.unexpected == ["yt-dlp-plugins/x/yt_dlp_plugins/extractor/evil.py"])
    }

    @Test func quarantineScanFindsTheAttribute() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try make()
        #expect(Quarantine.scan(root: root).isEmpty)
        let value = "0081;00000000;sudamp-test;"
        let rc = setxattr(root.appending(path: "_internal/sub/b.so").path, Quarantine.attribute, value, value.utf8.count, 0, 0)
        #expect(rc == 0)
        #expect(Quarantine.scan(root: root) == ["_internal/sub/b.so"])
    }
}
