// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Resolver

/// Fixture files under `Fixtures/ytdlp/` (located from this source file; no resource bundle needed).
enum Fixture {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/ytdlp", directoryHint: .isDirectory)

    static func url(_ path: String) -> URL { root.appending(path: path) }
    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
    static func text(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }
}

private let sha = String(repeating: "ab", count: 32)

@Suite struct EngineVersionTests {
    @Test(arguments: ["2026.10.21", "2026.10.21.232845", "2022.08.18.36"])
    func acceptsReleaseTags(_ s: String) {
        #expect(EngineVersion(s)?.string == s)
    }

    @Test(arguments: ["", "2026.10", "26.10.21", "2026.1.21", "2026.10.21.", "2026.10.21.x", "v2026.10.21",
                      "2026.10.21 ", "-2026.10.21", "2026.10.21.1.2", "2026.10.21;rm"])
    func rejectsEverythingElse(_ s: String) {
        #expect(EngineVersion(s) == nil)
    }

    @Test func ordersNumerically() {
        let v = ["2026.10.21", "2026.08.19", "2026.10.21.232845", "2025.12.31"].compactMap(EngineVersion.init).sorted()
        #expect(v.map(\.string) == ["2025.12.31", "2026.08.19", "2026.10.21", "2026.10.21.232845"])
    }
}

@Suite struct EngineChooserTests {
    @Test func blockedNewestReleaseMakesAFirstInstallPickThePin() {
        // PLAN M1: a fixture feed whose `block` lists the newest release → first install picks `pin`.
        let config = EngineInstallPolicy(pin: .init(version: "2026.08.19", sha256: sha), block: ["2026.10.21"])
        let choice = EngineChooser.choose(config: config, latest: "2026.10.21", recent: ["2026.10.21", "2026.08.19"])
        #expect(choice == EngineChoice(version: "2026.08.19", reason: .pin, expectedSHA256: sha))
    }

    @Test func pinWinsEvenWithoutBlock() {
        let config = EngineInstallPolicy(pin: .init(version: "2026.08.19", sha256: sha))
        #expect(EngineChooser.choose(config: config, latest: "2026.10.21")?.reason == .pin)
    }

    @Test func blockedPinFallsBackToLatest() {
        let config = EngineInstallPolicy(pin: .init(version: "2026.08.19", sha256: sha), block: ["2026.08.19"])
        #expect(EngineChooser.choose(config: config, latest: "2026.10.21")
            == EngineChoice(version: "2026.10.21", reason: .latest))
    }

    @Test func noPinTakesLatest() {
        #expect(EngineChooser.choose(config: EngineInstallPolicy(), latest: "2026.10.21")?.version == "2026.10.21")
    }

    @Test func blockedLatestTakesNewestNonBlocked() {
        let choice = EngineChooser.choose(config: EngineInstallPolicy(block: ["2026.10.21", "2026.08.19"]),
                                          latest: "2026.10.21",
                                          recent: ["2026.03.17", "2026.10.21", "2026.08.19", "2026.07.04"])
        #expect(choice == EngineChoice(version: "2026.07.04", reason: .newestNonBlocked))
    }

    @Test func invalidPinIsIgnoredAndReported() {
        let config = EngineInstallPolicy(pin: .init(version: "2026.08.19", sha256: "NOT-HEX"), block: ["latest", "2026.10.21"])
        let (valid, rejected) = config.validated()
        #expect(valid.pin == nil)
        #expect(valid.block == ["2026.10.21"])
        #expect(rejected == ["pin 2026.08.19", "block latest"])
        #expect(EngineChooser.choose(config: config, latest: "2026.10.21", recent: ["2026.08.19"])
            == EngineChoice(version: "2026.08.19", reason: .newestNonBlocked))
    }

    @Test func updateSpecLockCapsTheChoice() {
        let choice = EngineChooser.choose(config: EngineInstallPolicy(), latest: "2026.10.21", lockedTag: "2025.08.11")
        #expect(choice == EngineChoice(version: "2025.08.11", reason: .updateSpecLock))
        // A pin above the lock is not allowed either.
        let pinned = EngineInstallPolicy(pin: .init(version: "2026.08.19", sha256: sha))
        #expect(EngineChooser.choose(config: pinned, latest: "2026.10.21", lockedTag: "2025.08.11")?.version
            == "2025.08.11")
    }

    @Test func nothingAllowedGivesNil() {
        #expect(EngineChooser.choose(config: EngineInstallPolicy(block: ["2026.10.21"]), latest: "2026.10.21") == nil)
        #expect(EngineChooser.choose(config: EngineInstallPolicy(), latest: nil) == nil)
    }
}

@Suite struct UpdateSpecTests {
    let spec = UpdateSpec(parsing: (try? Fixture.text("upstream/_update_spec-2026.10.21")) ?? "")

    @Test func parsesTheRealFile() {
        #expect(spec.isVersion2)
        #expect(spec.locks.count == 25)
        #expect(spec.locks.first == .init(repo: "yt-dlp/yt-dlp", tag: "2022.08.18.36", pattern: ".+ Python 3\\.6"))
    }

    @Test func currentMacOnedirIsNotLocked() {
        let id = UpdateSpec.synthesizedIdentifier(
            osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1), machine: "arm64")
        #expect(id == "darwin_dir Python (CPython arm64 64bit) - macOS-27.0.1-arm64-arm-64bit")
        #expect(spec.lockedTag(identifier: id) == nil)
        // What 2026.10.21's `-v` header reports on the dev machine (R1).
        let real = "darwin_dir Python 3.14.7 (CPython arm64 64bit) - macOS-27.0.1-arm64-arm-64bit-Mach-O (OpenSSL 3.5.7 9 Jun 2026)"
        #expect(spec.lockedTag(identifier: real) == nil)
    }

    @Test func matchingLinesCapInFileOrder() {
        #expect(spec.lockedTag(identifier: "darwin_legacy_exe Python 3.9.0 (CPython x86_64 64bit) - macOS-10.14") == "2025.08.11")
        #expect(spec.lockedTag(identifier: "zip Python 3.9.18 (CPython arm64 64bit) - macOS-15.0") == "2025.10.14")
        #expect(spec.lockedTag(identifier: "zip Python 3.6.9 (CPython x86_64 64bit) - Linux") == "2022.08.18.36")
        // Nightly-repo lines don't apply to the stable repo, and vice versa.
        #expect(spec.lockedTag(identifier: "zip Python 3.9.18", repo: "yt-dlp/yt-dlp-nightly-builds") == "2025.10.14.232845")
    }

    @Test func versionOneFormatIsUsedWhenNoV2Lines() {
        let v1 = UpdateSpec(parsing: "# comment\nlock 2024.10.22 py2exe .+\nlock 2025.08.11 darwin_legacy_exe .+\n")
        #expect(!v1.isVersion2)
        #expect(v1.lockedTag(identifier: "darwin_legacy_exe Python 3.9") == "2025.08.11")
        #expect(v1.lockedTag(identifier: "darwin_dir Python 3.14") == nil)
    }
}

@Suite struct ReleaseParsingTests {
    @Test func checksumsFromTheRealFile() throws {
        let sums = SHA256Sums(parsing: try Fixture.text("upstream/SHA2-256SUMS-2026.10.21"))
        #expect(sums["yt-dlp_macos.zip"] == "2b5251788b36fcbc476568b4eea8cb239f0a775759456f2ff9344a437c52f000")
        #expect(sums["yt-dlp_macos"] == "7a6fe71d7d680f1fb0ac18d4949873d77db2859e90017c0f44bd94b23be4ee40")
        #expect(sums["nope"] == nil)
    }

    @Test func checksumsIgnoreJunkAndBinaryMarks() {
        let sums = SHA256Sums(parsing: "\(sha) *a.zip\nnot a line\nXYZ  b.zip\n\(sha.uppercased())  c.zip\n")
        #expect(sums.entries == ["a.zip": sha, "c.zip": sha])
    }

    @Test func tagFromLatestRedirect() {
        #expect(GitHubReleases.tag(fromReleaseURL: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.21")!)
            == "2026.10.21")
        #expect(GitHubReleases.tag(fromReleaseURL: URL(string: "https://github.com/yt-dlp/yt-dlp/releases")!) == nil)
        #expect(GitHubReleases.tag(fromReleaseURL: URL(string: "https://github.com/x/releases/tag/v1.0")!) == nil)
    }

    @Test func tagsFromAtomFeed() throws {
        let tags = GitHubReleases.tags(fromAtom: try Fixture.text("upstream/releases-2026.10.22.atom"))
        #expect(tags == ["2026.10.21", "2026.08.19", "2026.07.04", "2026.06.09", "2026.03.17", "2026.03.13"])
    }

    @Test func assetURLs() {
        let gh = GitHubReleases()
        #expect(gh.assetURL("yt-dlp_macos.zip", version: "2026.10.21").absoluteString
            == "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.21/yt-dlp_macos.zip")
    }
}
