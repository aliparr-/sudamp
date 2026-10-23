// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Core
import Playback
import SkinKit
import SkinUI

/// `--automation` for the skinned windows (PLAN M5): menus are opened at their anchors and their items chosen
/// through the menu; controls are pressed and sliders dragged through SkinUI's pointer state machine; skins load
/// through the same code as Open Skin…. Nothing takes focus from the owner, and no menu stays open for long.
extension SkinnedPlayerUI: PlayerFrontEnd {
    var modeName: String { "skinned" }

    // MARK: Core steps

    /// `selectGenre` / `surpriseMe` go through the genre menu under the marquee, as a click would.
    func automationSelect(_ choice: GenreMenuChoice) async -> (Bool, String?) {
        if openMenuKind != "genre" {
            openGenreMenu(.marquee)
            guard await waitForMenu(.genre, timeout: 3) else { return (false, "the genre menu did not open") }
        }
        return choose(where: { GenreMenuChoice($0) == choice }, describe: choice.tag)
    }

    func automationPress(_ control: AutomationScript.Control) {
        let main = manager.windows[.main]?.skinView
        switch control {
        case .play: main?.press(.play)
        case .pause: main?.press(.pause)
        case .stop: main?.press(.stop)
        case .next: main?.press(.next)
        case .previous: main?.press(.previous)
        case .playPause: main?.press(context.controller.snapshot.phase == .playing ? .pause : .play)
        case .retry: context.retry()
        }
    }

    func automationSetVolume(_ v: Double) {
        manager.windows[.main]?.skinView.dragSlider(.volume, toFraction: v / 100)
    }

    /// Main's picture (base + marquee + visualiser) at the current scale, as a PNG.
    func snapshot(to url: URL) throws {
        guard let view = manager.windows[.main]?.skinView, let picture = SkinPicture.composite(view) else {
            throw SkinPicture.Failure(description: "no frame drawn yet")
        }
        guard let png = SkinPicture.resized(picture, to: SkinScale.intSize(view.kind, scale: view.scale)).pngData() else {
            throw SkinPicture.Failure(description: "PNG encoding failed")
        }
        try png.write(to: url, options: .atomic)
    }

    var automationReport: [String: Any] {
        var report: [String: Any] = ["menuAutoOpened": menuAutoOpened, "menuSelections": menuSelections,
                                     "skinId": skinEntry.id]
        if !menuDumps.isEmpty { report["menus"] = menuDumps }
        if !openedMenus.isEmpty { report["openedMenus"] = openedMenus }
        return report
    }

    func automationWillStart(firstLaunch: Bool) {
        // The first-launch auto-open is the app's own launch behaviour; under automation it runs only when the
        // script waits for it (`waitForMenu auto`), so no other script leaves a menu on the owner's screen.
        if firstLaunch { openGenreMenuSoon() }
    }

    func automationDidFinish() {
        cancelMenuTracking()
        if let main = manager.windows[.main], let sheet = main.attachedSheet { main.endSheet(sheet) }
        manager.close()
    }

    // MARK: Skinned steps

    func perform(_ step: ShellAutomationScript.SkinStep) async -> (Bool, String?) {
        switch step {
        case .openGenreMenu(let anchor):
            switch anchor {
            case .contextMenu:
                let point = manager.marqueeMenuAnchor()
                popUp(contextMenu(), at: point, kind: "context", anchor: .contextMenu)
                return await waitForMenu(.context, timeout: 3) ? (true, "context menu (Genre ▸ inside)") : (false, "did not open")
            default:
                openGenreMenu(anchor)
                return await waitForMenu(.genre, timeout: 3) ? (true, nil) : (false, "the genre menu did not open")
            }
        case let .waitForMenu(kind, timeout):
            let ok = await waitForMenu(kind, timeout: timeout)
            return (ok, ok ? openMenuKind.map { "\($0) menu open (\(openMenuAnchor?.rawValue ?? "-"))" }
                    : "no \(kind.rawValue) menu within \(timeout) s")
        case .selectMenuItem(let path):
            return choose(path: path)
        case .selectMenuBarItem(let path):
            guard let main = NSApp.mainMenu, let item = MenuDump.find(path, in: main) else {
                return (false, "no menu-bar item \(path)")
            }
            item.menu?.update()
            guard item.isEnabled, let owner = item.menu else { return (false, "\(path) is disabled") }
            owner.performActionForItem(at: owner.index(of: item))
            menuSelections.append(["menu": "menuBar", "item": path, "anchor": "menuBar"])
            return (true, nil)
        case .cancelMenu:
            cancelMenuTracking()
            return (true, nil)
        case let .pressControl(name, window):
            guard let control = Control(rawValue: name), let role = SkinWindowRole(rawValue: window),
                  let view = manager.windows[role]?.skinView else { return (false, "unknown control \(name)") }
            guard Layout.rect(of: control, in: view.kind) != nil else { return (false, "\(name) is not in \(view.kind)") }
            return view.press(control) ? (true, nil) : (false, "\(name) did nothing")
        case let .dragSlider(name, value, window):
            guard let control = Control(rawValue: name), let role = SkinWindowRole(rawValue: window),
                  let view = manager.windows[role]?.skinView else { return (false, "unknown slider \(name)") }
            let fraction: Double
            switch control {
            case .volume, .position, .playlistScrollbar: fraction = value
            case .balance: fraction = SliderValues.balanceFraction(value)
            default: fraction = SliderValues.eqFraction(decibels: value)
            }
            return view.dragSlider(control, toFraction: fraction) ? (true, nil) : (false, "\(name) is not a working slider here")
        case let .loadSkin(spec, expectRejection):
            let before = context.controller.snapshot.lastError
            if library.entry(id: spec) != nil {
                _ = selectSkin(id: spec, origin: "automation")
            } else {
                loadSkinFiles([spec], origin: "automation")
            }
            let after = context.controller.snapshot.lastError
            let rejected = after != before && after?.kind == "skinRejected"
            let note = rejected ? "rejected: \(after?.message ?? "")" : "skin \(skinEntry.id)"
            return (rejected == expectRejection, note)
        case .dumpMenus(let label):
            menuDumps.append(dumpMenus(label: label))
            return (true, nil)
        case .showWindows:
            showWithoutActivating()
            return (true, nil)
        case .saveEQF(let path), .loadEQF(let path):
            let save: Bool = if case .saveEQF = step { true } else { false }
            injectedEQFURL = URL(filePath: (path as NSString).expandingTildeInPath)
            let presets = manager.windows[.equalizer]?.skinView.screenRect(forSkinRect: EQLayout.presets) ?? .zero
            popUp(presetsMenu(), at: CGPoint(x: presets.minX, y: presets.minY), kind: "presets", anchor: nil)
            guard await waitForMenu(.presets, timeout: 3) else {
                injectedEQFURL = nil
                return (false, "the presets menu did not open")
            }
            return choose(path: save ? "Save .eqf…" : "Load .eqf…")
        case .openStreamURL(let url):
            switch context.openStream(url, origin: "automation") {
            case .success: return (true, nil)
            case .failure(let error): return (false, error.description)
            }
        case .playRow(let row):
            manager.handle(.playlistRowActivated(index: row), from: .playlist)
            return (true, nil)
        }
    }

    /// Waits until a menu of `kind` is tracking (`auto`: the first-launch genre menu).
    func waitForMenu(_ kind: ShellAutomationScript.MenuKind, timeout: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        func matches() -> Bool {
            guard let open = openMenuKind, openMenu != nil else { return false }
            switch kind {
            case .any: return true
            case .auto: return open == "genre" && openMenuAnchor == .auto
            case .genre: return open == "genre"
            case .presets: return open == "presets"
            case .context: return open == "context"
            }
        }
        while Date() < deadline {
            if matches() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return matches()
    }

    /// Chooses an item of the open menu by its title path, through the menu.
    private func choose(path: String) -> (Bool, String?) {
        guard let menu = openMenu else { return (false, "no menu is open") }
        guard let item = MenuDump.find(path, in: menu) else { return (false, "no item \(path) in the \(openMenuKind ?? "") menu") }
        return select(item, in: menu, describe: path)
    }

    private func choose(where predicate: (NSMenuItem) -> Bool, describe: String) -> (Bool, String?) {
        guard let menu = openMenu else { return (false, "no menu is open") }
        guard let item = menu.items.first(where: predicate) else { return (false, "no item \(describe)") }
        return select(item, in: menu, describe: describe)
    }

    /// As a user's choice: the menu closes and the item's action is sent (NSMenu `performActionForItem(at:)`).
    private func select(_ item: NSMenuItem, in menu: NSMenu, describe: String) -> (Bool, String?) {
        guard item.isEnabled, item.submenu == nil, let owner = item.menu else {
            cancelMenuTracking()
            return (false, "\(describe) is disabled\(item.subtitle.map { " (\($0))" } ?? "")")
        }
        let anchor = openMenuAnchor?.rawValue ?? "-"
        let kind = openMenuKind ?? "-"
        menu.cancelTrackingWithoutAnimation()
        owner.performActionForItem(at: owner.index(of: item))
        if openMenu === menu { menuClosed() }
        return (true, "\(item.title) through the \(kind) menu (\(anchor))")
    }

    // MARK: Menus dump

    /// Every DESIGN §3 entry point's menu, the genre menu each one shows (compared without key equivalents), and
    /// the other menus, as data for the report.
    func dumpMenus(label: String?) -> [String: Any] {
        var genreMenus: [String: [MenuNode]] = [:]
        genreMenus[GenreMenuAnchor.marquee.rawValue] = MenuDump.genreNodes(genreMenu())
        genreMenus[GenreMenuAnchor.options.rawValue] = MenuDump.genreNodes(genreMenu())
        let context = contextMenu()
        if let submenu = context.items.first(where: { $0.title == "Genre" })?.submenu {
            genreMenus[GenreMenuAnchor.contextMenu.rawValue] = MenuDump.genreNodes(submenu)
        }
        if let menus = appMenus {
            genreMenus[GenreMenuAnchor.menuBar.rawValue] = MenuDump.genreNodes(menus.genreMenuForDump())
            genreMenus[GenreMenuAnchor.statusItem.rawValue] = MenuDump.genreNodes(menus.statusMenuForDump())
            genreMenus[GenreMenuAnchor.dock.rawValue] = MenuDump.genreNodes(menus.dockMenu())
        }
        let reference = genreMenus[GenreMenuAnchor.marquee.rawValue]
        let same = genreMenus.values.allSatisfy { $0 == reference }
        var out: [String: Any] = [
            "entryPoints": GenreMenuAnchor.entryPoints.map(\.rawValue).filter { genreMenus[$0] != nil },
            "sameGenreMenu": same,
            "genreMenus": Self.json(genreMenus),
            "contextMenu": Self.json(MenuDump.nodes(context)),
            "presetsMenu": Self.json(MenuDump.nodes(presetsMenu())),
            "skinsMenu": Self.json(MenuDump.nodes(skinsMenu())),
        ]
        if let menus = appMenus {
            out["menuBar"] = Self.json(NSApp.mainMenu.map { MenuDump.nodes($0) } ?? [])
            out["statusItem"] = Self.json(MenuDump.nodes(menus.statusMenuForDump()))
            out["dock"] = Self.json(MenuDump.nodes(menus.dockMenu()))
        }
        if let label { out["label"] = label }
        return out
    }

    static func json<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }
}
