// SPDX-License-Identifier: GPL-3.0-or-later
// The About window's content (DESIGN §6.5 stance, §8.3 trademark hygiene, §10 licence) and the third-party notices
// it shows: scripts/check-notices.sh passes on the committed THIRD_PARTY_NOTICES.md and fails when an entry is
// removed (PLAN M8 licence compliance, prepared in M7).
import AppKit
import Core
import Foundation
import Testing
@testable import Shell

@MainActor @Suite struct AboutWindowTests {
    @Test func contentCarriesTheStanceLicenceAndCredits() throws {
        let content = AboutContent(version: "1.2.3", build: "45")
        #expect(content.appName == "sudamp" && content.subtitle == "The Sudden Amp")
        #expect(content.versionLine == "Version 1.2.3 (build 45)")
        #expect(AboutContent(version: "1.2.3", build: nil).versionLine == "Version 1.2.3")
        #expect(AboutContent(version: "1.2.3", build: "1.2.3").versionLine == "Version 1.2.3")
        #expect(content.stance.contains("unofficial client"))
        #expect(content.stance.contains("belong to their creators"))
        #expect(content.licence.contains("GPL-3.0-or-later") && content.licence.contains("LGPL-2.1-or-later"))

        let names = content.credits.map(\.name)
        for required in ["Webamp", "Bitamp", "wamp", "macamp", "MacAmp", "AndAmp Dark and AndAmp Light", "mpv and FFmpeg",
                         "QuickJS-NG", "yt-dlp"] {
            #expect(names.contains(required), "missing credit \(required)")
        }
        let andamp = try #require(content.credits.first { $0.name.hasPrefix("AndAmp") })
        #expect(andamp.licence == "CC BY 4.0" && andamp.by.contains("Mattix"))
        let ytdlp = try #require(content.credits.first { $0.name == "yt-dlp" })
        #expect(ytdlp.role.contains("never bundled") && ytdlp.licence == "Unlicense")
        #expect(content.credits.first { $0.name == "QuickJS-NG" }?.licence == "MIT")
        for credit in content.credits { #expect(URL(string: credit.url)?.scheme == "https", "\(credit.name)") }
    }

    /// DESIGN §8.3: no Winamp name in sudamp's branding; "Winamp" only as a nominative reference.
    @Test func winampAppearsOnlyNominatively() {
        let content = AboutContent(version: "1")
        for own in [content.appName, content.subtitle] {
            #expect(!own.localizedCaseInsensitiveContains("winamp") && !own.localizedCaseInsensitiveContains("amp skin"))
        }
        let text = [content.summary, content.stance, content.licence, content.creditsText].joined(separator: " ")
        let mentions = text.components(separatedBy: "Winamp").count - 1
        let nominative = text.components(separatedBy: "plays classic Winamp skins").count - 1
            + text.components(separatedBy: "any radio station or Winamp.").count - 1
        #expect(mentions == 2 && mentions == nominative)
        #expect(!text.localizedCaseInsensitiveContains("llama"))
    }

    @Test func versionComesFromTheBundleAndTheSkinCreditIsShown() throws {
        let dir = try ShellTempDir()
        let app = dir.url.appending(path: "Probe.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "321", "CFBundleIdentifier": "test.probe"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))
        let skin = SkinEntry(id: "andamp-dark", name: "AndAmp Dark", origin: .bundled, url: nil, credit: SkinLibrary.andAmpCredit)
        let content = AboutContent.current(bundle: bundle, skin: skin)
        #expect(content.versionLine == "Version 9.8.7 (build 321)")
        #expect(content.currentSkin == "AndAmp Dark – AndAmp skin by Mattix (mattix.nl), CC BY 4.0")
        #expect(AboutContent.current(bundle: bundle, skin: SkinEntry(id: "sudamp-dark", name: "sudamp Dark", origin: .builtIn,
                                                                      url: nil, credit: nil)).currentSkin == nil)
    }

    @Test func documentsComeFromTheBundleOrTheRepository() throws {
        let dir = try ShellTempDir()
        let app = dir.url.appending(path: "Probe.app")
        let resources = app.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.probe"], format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))

        // Not in the bundle: found by walking up to the repository.
        let fromRepo = try #require(AboutDocument.notices.url(bundle: bundle, searchFrom: [ShellRepo.url("Sources/Shell")]))
        #expect(fromRepo.lastPathComponent == "THIRD_PARTY_NOTICES.md")
        #expect(AboutDocument.notices.text(bundle: bundle, searchFrom: [ShellRepo.root]).hasPrefix("# Third-party notices"))
        #expect(AboutDocument.licence.text(bundle: bundle, searchFrom: [ShellRepo.root]).contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(AboutDocument.credits.text(bundle: bundle, searchFrom: [ShellRepo.root]).hasPrefix("# Credits"))
        // Nowhere: an explanation instead of an empty window.
        #expect(AboutDocument.notices.url(bundle: bundle, searchFrom: [dir.url]) == nil)
        #expect(AboutDocument.notices.text(bundle: bundle, searchFrom: [dir.url]).contains("not included in this build"))
        // In the bundle's Resources: that copy wins.
        try Data("bundled notices".utf8).write(to: resources.appending(path: "THIRD_PARTY_NOTICES.md"))
        #expect(AboutDocument.notices.text(bundle: bundle, searchFrom: [ShellRepo.root]) == "bundled notices")
    }

    @Test func windowShowsTheContentWithoutBeingOpened() throws {
        _ = NSApplication.shared
        let controller = AboutWindowController(content: AboutContent(version: "1.0", build: "7"))
        let texts = controller.displayedText
        for expected in ["sudamp", "The Sudden Amp", "Version 1.0 (build 7)", AboutContent.stanceText, AboutContent.licenceText,
                         "Licence…", "Credits…", "Third-Party Notices…"] {
            #expect(texts.contains(expected), "missing \(expected)")
        }
        let credits = try #require(texts.last)
        #expect(credits.contains("Webamp by Jordan Eldredge") && credits.contains("yt-dlp by the yt-dlp contributors"))
        #expect(controller.window?.title == "About sudamp")
        #expect(controller.window?.isVisible == false)

        let viewer = AboutDocumentWindowController(document: .notices, bundle: .main, searchFrom: [ShellRepo.root])
        #expect(viewer.window?.title == "Third-Party Notices")
        #expect(viewer.displayedText.hasPrefix("# Third-party notices"))
    }
}

/// `SUDAMP_ABOUT_SNAPSHOT=/path/about.png` renders the About window offscreen to a PNG for a visual check (no window
/// is ever shown; skipped otherwise).
@MainActor @Suite struct AboutWindowSnapshot {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUDAMP_ABOUT_SNAPSHOT"] != nil))
    func renderToPNG() throws {
        _ = NSApplication.shared
        let path = try #require(ProcessInfo.processInfo.environment["SUDAMP_ABOUT_SNAPSHOT"])
        let skin = SkinEntry(id: "andamp-dark", name: "AndAmp Dark", origin: .bundled, url: nil, credit: SkinLibrary.andAmpCredit)
        var content = AboutContent.current(skin: skin)
        content.version = BuildInfo.version
        let controller = AboutWindowController(content: content)
        let appearance = ProcessInfo.processInfo.environment["SUDAMP_ABOUT_APPEARANCE"] == "dark" ? NSAppearance.Name.darkAqua : .aqua
        controller.window?.appearance = NSAppearance(named: appearance)
        let view = try #require(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        // The content view has no background of its own (the window draws it): paint one first.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

/// scripts/check-notices.sh against the committed THIRD_PARTY_NOTICES.md.
@Suite(.serialized) struct ThirdPartyNoticesTests {
    static func run(_ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await offPool { try runBlocking(arguments) }
    }

    private static func runBlocking(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [ShellRepo.url("scripts/check-notices.sh").path] + arguments
        process.currentDirectoryURL = ShellRepo.root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func committedNoticesCoverTheLinkSet() async throws {
        let (status, output) = try await Self.run([])
        #expect(status == 0, "\(output)")
        #expect(output.contains("29 MPVKit binary targets"), "\(output)")
    }

    /// Each kind of entry the script requires: a linked MPVKit library, a system library, the bundled helper and
    /// skin, and a PROVENANCE MIT notice. Removing any one must fail the check and name it.
    @Test(arguments: [
        ("| `Libmpv` |", "Libmpv"),
        ("| `Libavcodec` |", "Libavcodec"),
        ("| `Libssl` |", "Libssl"),
        ("| `libz` |", "libz"),
        ("| `qjs` |", "qjs"),
        ("| `AndAmp-Dark.wsz` |", "AndAmp-Dark.wsz"),
        ("### MIT © 2015 Jordan Eldredge", "Jordan Eldredge"),
    ])
    func removingAnEntryFails(line: String, name: String) async throws {
        let notices = try String(contentsOf: ShellRepo.url("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        let kept = notices.components(separatedBy: "\n").filter { !$0.hasPrefix(line) }
        #expect(kept.count < notices.components(separatedBy: "\n").count, "fixture line \(line) not found")
        let dir = try ShellTempDir()
        let copy = dir.url.appending(path: "THIRD_PARTY_NOTICES.md")
        try kept.joined(separator: "\n").write(to: copy, atomically: true, encoding: .utf8)
        let (status, output) = try await Self.run(["--notices", copy.path, "--link-map", "none"])
        #expect(status == 1, "\(output)")
        #expect(output.contains(name), "\(output)")
    }

    @Test func versionDriftFromMPVKitFails() async throws {
        let notices = try String(contentsOf: ShellRepo.url("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        let drifted = notices.replacingOccurrences(of: "| openssl-build 3.3.5 |", with: "| openssl-build 3.3.4 |")
        #expect(drifted != notices)
        let dir = try ShellTempDir()
        let copy = dir.url.appending(path: "notices.md")
        try drifted.write(to: copy, atomically: true, encoding: .utf8)
        let (status, output) = try await Self.run(["--notices", copy.path, "--link-map", "none"])
        #expect(status == 1 && output.contains("Libcrypto") && output.contains("openssl-build 3.3.5"), "\(output)")
    }
}
