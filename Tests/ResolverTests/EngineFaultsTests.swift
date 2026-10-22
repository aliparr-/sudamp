// SPDX-License-Identifier: GPL-3.0-or-later
import Core
import Foundation
import Synchronization
import Testing
@testable import Resolver

/// Serves a release zip in chunks, reporting progress after each one, like a real streaming download.
final class ChunkedReleases: EngineReleaseSource {
    let base: FakeReleases
    let chunks: Int
    let resumedFrom = Mutex<[Int64]>([])

    init(_ base: FakeReleases, chunks: Int = 10) {
        self.base = base
        self.chunks = chunks
    }

    var name: String { base.name }
    func latestVersion() async throws -> String { try await base.latestVersion() }
    func recentVersions() async throws -> [String] { try await base.recentVersions() }
    func updateSpec() async throws -> String? { try await base.updateSpec() }
    func checksums(version: String) async throws -> String { try await base.checksums(version: version) }

    func download(asset: String, version: String, to file: URL,
                  progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> DownloadOutcome {
        let scratch = file.deletingLastPathComponent().appending(path: "full-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try await base.download(asset: asset, version: version, to: scratch, progress: nil)
        let zip = try Data(contentsOf: scratch)
        let have = (try? Data(contentsOf: file)) ?? Data()
        resumedFrom.withLock { $0.append(Int64(have.count)) }
        var body = have
        let step = max(1, zip.count / chunks)
        var offset = have.count
        while offset < zip.count {
            try Task.checkCancellation()
            let end = min(zip.count, offset + step)
            body.append(zip[offset..<end])
            try body.write(to: file)
            offset = end
            progress?(Int64(offset), Int64(zip.count))
            await Task.yield()
            try await Task.sleep(for: .milliseconds(2))
        }
        return DownloadOutcome(bytesOnDisk: Int64(body.count), resumedFrom: Int64(have.count),
                               bytesReceived: Int64(body.count - have.count), httpStatus: have.isEmpty ? 200 : 206,
                               sentRange: !have.isEmpty)
    }
}

@Suite(.serialized) struct EngineFaultsTests {
    let profile = FileManager.default.temporaryDirectory.appending(path: "engine-faults-\(UUID().uuidString)")
    var layout: EngineLayout { EngineLayout(paths: .profile(profile)) }

    @Test func parsesTheFaultGrammar() {
        #expect(EngineFaults.parse("") == .none)
        #expect(EngineFaults.parse("engine:unreachable") == EngineFaults(unreachable: true))
        #expect(EngineFaults.parse("disk:full, engine:abort-at=50") == EngineFaults(abortAtPercent: 50, diskFull: true))
        #expect(EngineFaults.parse("youtube:jsless-fail,engine:abort-at=0,engine:abort-at=x") == .none,
                "other modules' faults and out-of-range values are ignored")
        #expect(!EngineFaults.none.isActive && EngineFaults(diskFull: true).isActive)
        #if DEBUG
        #expect(EngineFaults.from(environment: ["SUDAMP_FAULT": "engine:unreachable"]).unreachable)
        #endif
    }

    @Test func unreachableFailsTheInstallAsUnreachable() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let faults = EngineFaults(unreachable: true)
        let store = EngineStore(layout: layout, releases: faults.releases(releases))
        do {
            _ = try await store.install(config: EngineInstallPolicy())
            Issue.record("install should fail")
        } catch EngineStoreError.unreachable {
        } catch {
            Issue.record("expected unreachable, got \(error)")
        }
        #expect(releases.downloads.withLock { $0 }.isEmpty)
    }

    @Test func diskFullStartsNoDownload() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        let releases = try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"])
        let faults = EngineFaults(diskFull: true)
        let store = EngineStore(layout: layout, releases: faults.releases(releases),
                                freeSpace: faults.freeSpace { _ in 10_000_000_000 })
        await #expect(throws: EngineStoreError.insufficientSpace(available: 0, required: EngineStore.requiredFreeBytes)) {
            try await store.install(config: EngineInstallPolicy())
        }
        #expect(releases.downloads.withLock { $0 }.isEmpty)
    }

    @Test func abortAtCutsTheDownloadOnceAndARetryResumesWithRange() async throws {
        defer { try? FileManager.default.removeItem(at: profile) }
        FaultInjectingReleases.resetForTesting()
        defer { FaultInjectingReleases.resetForTesting() }
        let releases = ChunkedReleases(try FakeReleases(latest: "2026.10.21", versions: ["2026.10.21"]), chunks: 20)
        let faults = EngineFaults(abortAtPercent: 50)
        let store = EngineStore(layout: layout, releases: faults.releases(releases))
        do {
            _ = try await store.install(config: EngineInstallPolicy())
            Issue.record("the first install should be cut")
        } catch EngineStoreError.unreachable {
        } catch {
            Issue.record("expected unreachable, got \(error)")
        }
        let partial = layout.partialDirectory("2026.10.21").appending(path: "yt-dlp_macos.zip")
        let kept = (try? Data(contentsOf: partial))?.count ?? 0
        #expect(kept > 0, "the .partial keeps what arrived")

        // Next attempt (a relaunch, or the in-process retry): the latch has fired, the download resumes.
        let report = try await EngineStore(layout: layout, releases: faults.releases(releases))
            .install(config: EngineInstallPolicy())
        #expect(report.download?.sentRange == true && report.download?.resumedFrom == Int64(kept))
        #expect(report.upstreamMatch)
        #expect(releases.resumedFrom.withLock { $0 } == [0, Int64(kept)])
    }
}
