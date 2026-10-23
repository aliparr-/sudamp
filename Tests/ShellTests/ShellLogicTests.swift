// SPDX-License-Identifier: GPL-3.0-or-later
// The genre menu tree (one builder, every anchor), Copy Link, Open Stream URL, the skin library (loading, import,
// rejection), the command line, the automation script, and the app snapshot goldens.
import AppKit
import Catalog
import Core
import CryptoKit
import Foundation
import Playback
import SkinKit
import SkinUI
import Testing
@testable import Shell

@MainActor @Suite struct GenreMenuTests {
    final class Target: NSObject {
        @objc func chosen(_ sender: Any?) {}
    }

    let target = Target()

    func content(favourites: Int = 0, recent: [StreamRef] = []) -> GenreMenuContent {
        let rows = GenreMenuModel.items(
            genres: [Genre(id: deepHouseID, name: "Deep House", order: 1), Genre(id: technoID, name: "Techno", order: 2)],
            availability: [technoID: GenreAvailability(eligible: 0, total: 4, reason: .backingOff)],
            current: deepHouseID, shortcuts: true)
        return GenreMenuContent(rows: rows, favouritesCount: favourites, favouritesActive: false,
                                recent: recent.map(GenreMenuContent.streamRow))
    }

    @Test func theMenuEndsWithFavouritesSurpriseAndRecentlyPlayed() {
        let menu = GenreMenuBuilder.menu(content(favourites: 2, recent: [mix(1), mix(2, source: .radio)]), target: target,
                                         action: #selector(Target.chosen(_:)))
        #expect(menu.items.map(\.title) == ["Deep House", "Techno", "", "★ Favourites", "Surprise Me", "Recently Played"])
        #expect(menu.items[0].state == .on, "the current genre is ticked")
        #expect(!menu.items[1].isEnabled && menu.items[1].subtitle == "Streams unavailable - retrying soon")
        #expect(menu.items[3].isEnabled && GenreMenuChoice(menu.items[3]) == .favourites)
        let recent = try! #require(menu.items[5].submenu)
        #expect(recent.items.map(\.title) == ["Creator 1 - Mix 1  [YT]", "Station 2  [FM]"])
        #expect(GenreMenuChoice(recent.items[0]) == .stream(mix(1).id))
        #expect(menu.items.allSatisfy { $0.tag == GenreMenuBuilder.itemTag }, "every item is marked for the dump")
    }

    @Test func emptyFavouritesAndHistoryExplainThemselves() {
        let menu = GenreMenuBuilder.menu(content(), target: target, action: #selector(Target.chosen(_:)))
        let favourites = menu.items[3]
        #expect(!favourites.isEnabled && favourites.subtitle == GenreMenuContent.noFavourites)
        #expect(menu.items[5].submenu?.items.map(\.title) == [GenreMenuContent.nothingRecent])
    }

    @Test func shortcutsOnlyWhereAsked() {
        let bar = GenreMenuBuilder.items(content(), target: target, action: #selector(Target.chosen(_:)), shortcuts: true)
        #expect(bar[0].keyEquivalent == "1" && bar[0].keyEquivalentModifierMask == .command)
        #expect(bar.first { GenreMenuChoice($0) == .surpriseMe }?.keyEquivalent == "0")
        let popup = GenreMenuBuilder.menu(content(), target: target, action: #selector(Target.chosen(_:)))
        #expect(popup.items.allSatisfy { $0.keyEquivalent.isEmpty })
        // The dump compares anchors without key equivalents: the same menu either way.
        let barMenu = NSMenu()
        for item in bar { barMenu.addItem(item) }
        #expect(MenuDump.genreNodes(barMenu) == MenuDump.genreNodes(popup))
    }

    @Test func choicesRoundTripThroughTheirTags() {
        for choice: GenreMenuChoice in [.genre(deepHouseID), .surpriseMe, .favourites, .stream(mix(3).id),
                                        .stream(StreamID(rawValue: "radio:deep-radio")!)] {
            #expect(GenreMenuChoice(tag: choice.tag) == choice)
        }
        #expect(GenreMenuChoice(tag: "stream:nonsense") == nil)
    }

    @Test func menuPathsFindNestedItems() {
        let root = NSMenu()
        let genre = NSMenuItem(title: "Genre", action: nil, keyEquivalent: "")
        genre.submenu = GenreMenuBuilder.menu(content(recent: [mix(1)]), target: target, action: #selector(Target.chosen(_:)))
        root.addItem(genre)
        root.addItem(withTitle: "Open Stream URL…", action: nil, keyEquivalent: "l")
        #expect(MenuDump.find("Genre/Techno", in: root)?.title == "Techno")
        #expect(MenuDump.find("genre/recently played/creator 1", in: root)?.title == "Creator 1 - Mix 1  [YT]")
        #expect(MenuDump.find("Open Stream URL", in: root) != nil, "a trailing … is optional")
        #expect(MenuDump.find("Genre/Jazz", in: root) == nil)
        let node = MenuDump.node(root.items[1])
        #expect(node.key == "⌘l")
    }
}

@Suite struct CopyLinkTests {
    @Test func youTubeCarriesTheSecond() {
        let link = CopyLink.link(for: StreamInfo(mix(1)), position: 754.9)
        #expect(link?.url.absoluteString == "https://www.youtube.com/watch?v=VID00000001&t=754s")
        #expect(link?.text == "Creator 1 - Mix 1 https://www.youtube.com/watch?v=VID00000001&t=754s", "credits the creator")
    }

    @Test func soundCloudUsesMinutesAndSeconds() {
        let link = CopyLink.link(for: StreamInfo(mix(2, source: .soundcloud)), position: 3725)
        #expect(link?.url.absoluteString == "https://soundcloud.com/user2/track-2#t=62:05")
        #expect(CopyLink.soundCloudTime(65) == "1:05" && CopyLink.soundCloudTime(0) == "0:00")
    }

    @Test func noTimestampWhereThePlatformHasNone() {
        #expect(CopyLink.link(for: StreamInfo(mix(3, source: .mixcloud)), position: 600)?.url.absoluteString
            == "https://www.mixcloud.com/User3/show-3/")
        #expect(CopyLink.link(for: StreamInfo(mix(4, source: .youtubeLive)), position: 600)?.url.absoluteString
            == "https://www.youtube.com/@live4xx/live")
        let radio = CopyLink.link(for: StreamInfo(mix(5, source: .radio)), position: 600)
        #expect(radio?.url.absoluteString == "https://radiostation.fm/5" && radio?.text == "Station 5 https://radiostation.fm/5")
        #expect(CopyLink.link(for: StreamInfo(mix(1)), position: 0.4)?.url.absoluteString
            == "https://www.youtube.com/watch?v=VID00000001", "the very start needs no t=")
    }
}

@Suite struct StreamURLOpenerTests {
    let catalog = catalogOf([mix(1), mix(2, source: .radio)])

    @Test func catalogStreamsPlayAsThemselvesWithTheirStart() throws {
        let outcome = try StreamURLOpener.resolve("https://youtu.be/VID00000001?t=90", catalog: catalog, genre: nil)
        #expect(outcome == .catalog(mix(1).id, startAt: 90))
        let station = try StreamURLOpener.resolve("stream2.radiostation.fm/live", catalog: catalog, genre: nil)
        #expect(station == .catalog(mix(2, source: .radio).id, startAt: nil))
    }

    @Test func otherLinksBecomeOneOffStreams() throws {
        guard case let .adHoc(ref, start) = try StreamURLOpener.resolve(
            "https://soundcloud.com/someone/a-track#t=1:30", catalog: catalog, genre: deepHouseID) else {
            Issue.record("expected a one-off stream")
            return
        }
        #expect(ref.id.rawValue == "sc:someone/a-track" && ref.genres == [deepHouseID] && start == 90)
        guard case let .adHoc(radio, _) = try StreamURLOpener.resolve("https://ice.example-radio.net/stream",
                                                                      catalog: catalog, genre: nil) else {
            Issue.record("expected a one-off station")
            return
        }
        #expect(radio.isRadio && radio.id.rawValue.hasPrefix("radio:pasted-") && radio.genres.isEmpty)
        #expect(StreamURLOpener.radioSlug("https://a.fm/x") == StreamURLOpener.radioSlug("https://a.fm/x"))
    }

    @Test func refusedLinksSayWhy() {
        for bad in ["https://www.youtube.com/feed/trending", "ftp://radio.fm/x", "http://127.0.0.1/stream", "not a url"] {
            #expect(throws: CanonicalError.self, "\(bad)") { _ = try StreamURLOpener.resolve(bad, catalog: catalog, genre: nil) }
        }
        #expect(StreamURLOpener.explanation(.unrecognisedURL).contains("single mix"))
    }
}

@MainActor @Suite(.serialized) struct SkinLibraryTests {
    let bundled = ShellRepo.url("Fixtures/skins")

    @Test func builtInFirstThenBundled() {
        let library = SkinLibrary(bundledDirectory: bundled, userDirectory: URL(filePath: "/nonexistent"))
        let entries = library.entries()
        #expect(entries.map(\.id) == ["sudamp-dark", "andamp-dark", "andamp-light", "andamp-spot"])
        #expect(entries[1].name == "AndAmp Dark" && entries[1].credit == SkinLibrary.andAmpCredit)
        #expect(entries[3].name == "AndAmp Spot" && entries[3].credit == SkinLibrary.andAmpCredit)
        #expect(!entries.contains { $0.origin == .museum }, "the repository holds the museum list, not the skins")
        guard case .success(let skin) = library.load(entries[1]) else {
            Issue.record("AndAmp Dark should load")
            return
        }
        #expect(skin.report.regionSections.isEmpty == false || skin.name == "AndAmp-Dark")
    }

    @Test func importedSkinsAreCopiedIntoTheProfile() throws {
        let temp = try ShellTempDir()
        let user = temp.url.appending(path: "Skins")
        let library = SkinLibrary(bundledDirectory: nil, userDirectory: user)
        let outside = temp.url.appending(path: "My Skin.wsz")
        try FileManager.default.copyItem(at: bundled.appending(path: "AndAmp-Light.wsz"), to: outside)
        guard case .success(let (entry, _)) = library.importSkin(at: outside) else {
            Issue.record("a real skin imports")
            return
        }
        #expect(entry.id == "user:my skin" && entry.origin == .user)
        #expect(FileManager.default.fileExists(atPath: user.appending(path: "My Skin.wsz").path))
        #expect(library.entries().map(\.id).contains("user:my skin"), "listed in the Skins menu from now on")
    }

    @Test func aCopyOfABundledSkinIsThatSkin() throws {
        let temp = try ShellTempDir()
        let library = SkinLibrary(bundledDirectory: bundled, userDirectory: temp.url.appending(path: "Skins"))
        let copy = temp.url.appending(path: "dark-copy.wsz")
        try FileManager.default.copyItem(at: bundled.appending(path: "AndAmp-Dark.wsz"), to: copy)
        guard case .success(let (entry, _)) = library.importSkin(at: copy) else {
            Issue.record("imports")
            return
        }
        #expect(entry.id == "andamp-dark")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appending(path: "Skins").path), "nothing copied")
    }

    /// `Skins/Museum/museum.json` names the bundled museum skins; each is `<md5>.wsz` beside it.
    @Test func museumSkinsComeFromTheirList() throws {
        let temp = try ShellTempDir()
        let skins = temp.url.appending(path: "Skins")
        let museum = skins.appending(path: SkinLibrary.museumFolder)
        try FileManager.default.createDirectory(at: museum, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundled.appending(path: "AndAmp-Light.wsz"),
                                         to: skins.appending(path: "AndAmp-Light.wsz"))
        let data = try Data(contentsOf: bundled.appending(path: "AndAmp-Spot.wsz"))
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try data.write(to: museum.appending(path: md5 + ".wsz"))
        let list = """
            {"about": "test", "skins": [
              {"md5": "\(md5)", "file": "Spot_copy.wsz", "name": "Zebra Spot"},
              {"md5": "\(String(repeating: "0", count: 32))", "file": "gone.wsz", "name": "Gone"},
              {"md5": "../AndAmp-Light", "file": "x.wsz", "name": "Escape"}
            ]}
            """
        try Data(list.utf8).write(to: museum.appending(path: "museum.json"))
        let user = temp.url.appending(path: "User")
        let library = SkinLibrary(bundledDirectory: skins, userDirectory: user)
        let entries = library.entries()
        #expect(entries.map(\.id) == ["sudamp-dark", "andamp-light", "museum:" + md5],
                "after the bundled skins; a missing file or a key that isn't an MD5 is left out")
        let entry = try #require(entries.last)
        #expect(entry.name == "Zebra Spot" && entry.origin == .museum)
        #expect(entry.credit == "Spot_copy.wsz from the Winamp Skin Museum (skins.webamp.org), © its author")
        guard case .success(let skin) = library.load(entry) else {
            Issue.record("a museum skin loads")
            return
        }
        #expect(SkinLibrary.debugInfo(entry, skin: skin).origin == "museum")
        // The same file opened from elsewhere is that museum skin, not a new user skin.
        let copy = temp.url.appending(path: "spot.wsz")
        try data.write(to: copy)
        guard case .success(let (imported, _)) = library.importSkin(at: copy) else {
            Issue.record("imports")
            return
        }
        #expect(imported.id == "museum:" + md5)
        #expect(!FileManager.default.fileExists(atPath: user.path), "nothing copied")
    }

    /// Fixtures/skins/museum.json, which scripts/fetch-museum-skins.sh and the app read.
    @Test func theCommittedMuseumListIsWellFormed() throws {
        struct Listing: Decodable {
            struct Skin: Decodable { var md5, file, name: String }
            var skins: [Skin]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: Data(contentsOf: bundled.appending(path: "museum.json")))
        #expect(listing.skins.count == 100)
        #expect(Set(listing.skins.map(\.md5)).count == listing.skins.count, "no skin twice")
        #expect(Set(listing.skins.map { $0.name.lowercased() }).count == listing.skins.count, "menu names are unique")
        for skin in listing.skins {
            #expect(skin.md5.count == 32 && skin.md5.allSatisfy { "0123456789abcdef".contains($0) }, "\(skin.md5)")
            #expect(!skin.file.isEmpty && !skin.name.isEmpty
                    && skin.name == skin.name.trimmingCharacters(in: .whitespacesAndNewlines), "\(skin.file)")
        }
    }

    @Test func bombsAndNonSkinsAreRefusedAndNotCopied() throws {
        let temp = try ShellTempDir()
        let user = temp.url.appending(path: "Skins")
        let library = SkinLibrary(bundledDirectory: nil, userDirectory: user)
        let bomb = temp.url.appending(path: "bomb.wsz")
        try ZipBomb.make(uncompressedSize: 64 << 20).write(to: bomb)
        guard case .failure(let rejection) = library.importSkin(at: bomb) else {
            Issue.record("a zip bomb must be refused")
            return
        }
        #expect(rejection.reason == "entryTooLarge" && rejection.file == "bomb.wsz")
        #expect(rejection.message.contains("refused to unpack"))
        let notSkin = temp.url.appending(path: "notes.zip")
        try ZipWriter.archive([.init(path: "readme.txt", data: Data("hello".utf8))]).write(to: notSkin)
        guard case .failure(let other) = library.importSkin(at: notSkin) else {
            Issue.record("a zip without skin files must be refused")
            return
        }
        #expect(other.reason == "notASkin")
        #expect(!FileManager.default.fileExists(atPath: user.path), "nothing refused is copied")
    }

    @Test func debugInfoNamesTheSkin() {
        let info = SkinLibrary.debugInfo(SkinLibrary.builtIn, skin: SudampDark.skin)
        #expect(info.id == "sudamp-dark" && info.origin == "builtIn" && info.fallbackSheets.isEmpty)
    }
}

@Suite struct ShellArgumentsTests {
    @Test func skinFilesAndOptionsAreTakenOut() throws {
        let a = try ShellArguments.parse(["--mute", "x/AndAmp.wsz", "--scale", "2", "--profile", "/tmp/p", "--no-region",
                                          "sudamp://genre/techno", "--ignore-occlusion"])
        #expect(a.skinFiles == ["x/AndAmp.wsz"] && a.scale == 2 && a.noRegion && a.ignoreOcclusion)
        #expect(a.remaining == ["--mute", "--profile", "/tmp/p", "sudamp://genre/techno"])
        #expect(throws: ShellArguments.ParseError.self) { _ = try ShellArguments.parse(["--scale", "4"]) }
        #expect(throws: ShellArguments.ParseError.self) { _ = try ShellArguments.parse(["--scale", "1.3"]) }
        #expect(try ShellArguments.parse(["--scale", "1.5"]).scale == 1.5)
    }

    @Test func snapshotStatesTakeEveryFollowingPath() throws {
        let a = try ShellArguments.parse(["--snapshot", "out", "--states", "a.json", "b.json", "--mute"])
        #expect(a.snapshotDirectory == "out" && a.states == ["a.json", "b.json"] && a.remaining == ["--mute"])
        #expect(throws: ShellArguments.ParseError.statesWithoutSnapshot) { _ = try ShellArguments.parse(["--states", "a.json"]) }
    }

    @Test func forwardedSkinPathsBecomeAbsolute() {
        let args = ShellArguments.forwardedArguments(["--profile", "/p", "skins/X.wsz", "~/Y.zip", "sudamp://next"],
                                                     relativeTo: "/work")
        #expect(args[2] == "/work/skins/X.wsz" && args[3].hasPrefix("/") && args[3].hasSuffix("/Y.zip") && args[4] == "sudamp://next")
        #expect(ShellArguments.skinFiles(in: args) == [args[2], args[3]])
        #expect(!ShellArguments.isSkinPath("--skin.wsz") && !ShellArguments.isSkinPath("https://x.fm/a.zip"))
    }
}

@Suite struct ShellAutomationScriptTests {
    @Test func skinnedAndCoreStepsMix() throws {
        let json = #"""
        {"name": "t", "timeout": 7, "steps": [
          {"waitForMenu": "auto"}, {"selectMenuItem": "Deep House"}, {"waitFor": "playing"},
          {"pressControl": "eqOn", "window": "equalizer"}, {"dragSlider": "band3", "value": 6, "window": "equalizer"},
          {"loadSkin": "/tmp/bomb.wsz", "expect": "rejected"}, "dumpMenus", "showWindows", "cancelMenu",
          {"openGenreMenu": "options"}, {"saveEQF": "/tmp/a.eqf"}, {"playRow": 3}, "pressNext"
        ]}
        """#
        let script = try ShellAutomationScript.parse(Data(json.utf8))
        #expect(script.name == "t")
        #expect(script.steps == [
            .skin(.waitForMenu(.auto, timeout: 7)), .skin(.selectMenuItem("Deep House")),
            .core(.waitFor(states: ["playing"], timeout: 7)), .skin(.pressControl("eqOn", window: "equalizer")),
            .skin(.dragSlider("band3", value: 6, window: "equalizer")),
            .skin(.loadSkin("/tmp/bomb.wsz", expectRejection: true)), .skin(.dumpMenus(label: nil)), .skin(.showWindows),
            .skin(.cancelMenu), .skin(.openGenreMenu(.options)), .skin(.saveEQF("/tmp/a.eqf")), .skin(.playRow(3)),
            .core(.press(.next)),
        ])
        #expect(script.steps.filter(\.needsSkinnedUI).count == 11)
    }

    @Test func mistakesAreReportedAtTheirStep() {
        #expect(throws: AutomationScriptError.badValue(step: 1, key: "window")) {
            _ = try ShellAutomationScript.parse(Data(#"["pressNext", {"pressControl": "play", "window": "dock"}]"#.utf8))
        }
        #expect(throws: AutomationScriptError.badValue(step: 0, key: "openGenreMenu")) {
            _ = try ShellAutomationScript.parse(Data(#"[{"openGenreMenu": "dock"}]"#.utf8))
        }
        #expect(throws: AutomationScriptError.unknownStep(index: 2, "fly")) {
            _ = try ShellAutomationScript.parse(Data(#"["pressNext", "dumpState", "fly"]"#.utf8))
        }
        #expect(throws: AutomationScriptError.unknownState(index: 0, "dancing")) {
            _ = try ShellAutomationScript.parse(Data(#"[{"waitFor": "dancing"}]"#.utf8))
        }
    }

    @Test func skipsAppendCoreSteps() {
        var script = ShellAutomationScript(name: nil, steps: [])
        script.appendSkips(2, dwell: 5)
        #expect(script.steps.count == 6 && script.steps[1] == .core(.press(.next)))
    }

    @Test func theRepositoryScriptsParse() throws {
        for name in ["northstar", "menus", "eqf-roundtrip", "northstar-plain"] {
            _ = try ShellAutomationScript.load(from: ShellRepo.url("Fixtures/automation/\(name).json"))
        }
    }
}

@MainActor @Suite(.serialized) struct AppSnapshotGoldenTests {
    /// PLAN M5: `sudamp --snapshot out --states Fixtures/states/app/*.json` matches every committed golden.
    @Test func everyAppStateMatchesItsGolden() throws {
        let dir = ShellRepo.url("Fixtures/states/app")
        let goldens = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: dir.appending(path: "goldens.json")))
        let states = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") && $0 != "goldens.json" }.sorted()
        #expect(states.count == 12 && goldens.count == 12)
        var windows = Set<String>(), scales = Set<Int>()
        let library = SkinLibrary(bundledDirectory: ShellRepo.url("Fixtures/skins"), userDirectory: URL(filePath: "/nonexistent"))
        for file in states {
            let name = String(file.dropLast(5))
            let rendered = try AppSnapshot.render(AppSnapshot.load(dir.appending(path: file).path), name: name, library: library)
            #expect(rendered.sha256 == goldens[name], "\(name)")
            windows.insert(rendered.window)
            scales.insert(rendered.scale)
        }
        #expect(windows == ["main", "shade", "equalizer", "playlist"] && scales == [1, 2])
    }

    @Test func picturesScaleUpPixelExactly() {
        var bitmap = Bitmap(width: 2, height: 1)
        bitmap.fill(IntRect(1, 0, 1, 1), .white)
        let big = SkinPicture.upscaled(bitmap, by: 3)
        #expect(big.width == 6 && big.height == 3)
        #expect(big[2, 2] == .clear && big[3, 0] == .white && big[5, 2] == .white)
        // In between, each pixel samples the skin pixel under its centre.
        let wider = SkinPicture.resized(bitmap, to: IntSize(3, 2))
        #expect(wider.width == 3 && wider.height == 2)
        #expect(wider[0, 0] == .clear && wider[1, 0] == .white && wider[2, 1] == .white)
    }
}
