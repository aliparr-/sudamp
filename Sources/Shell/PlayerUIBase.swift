// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Audio
import Catalog
import Core
import Playback
import SkinKit
import SkinUI

/// What both skin classes' front ends share (DESIGN §8.4): the classic `.wsz` windows (`SkinnedPlayerUI`) and the
/// modern glass window (`ModernPlayerUI`). Every pop-up menu (the genre menu from every anchor, the context menu,
/// EQ presets with Load/Save .eqf…, visualiser, stream info), menu tracking, window-modal sheets, and the automation
/// steps that work through menus. The front ends say where the genre menu opens, which window sheets attach to, and
/// what their View menu holds.
///
/// Every menu pops up from a zero-delay run-loop perform in the common modes, whoever asked (a click, a key, the
/// first-launch auto-open, automation): `NSMenu.popUp` runs a nested tracking loop, and from inside a main-queue job
/// (every main-actor task is one) that loop could not run main-actor work (M2 finding), so hover pre-resolve and
/// automation would stall until the menu closed.
class PlayerUIBase: NSObject, NSMenuDelegate, NSOpenSavePanelDelegate {
    let context: AppContext
    let isAutomation: Bool
    /// The menu bar, status item and Dock (menus dump).
    weak var appMenus: AppMenus?
    /// The Skins menu, built by `PlayerStyleHost` (both classes, the modern appearance and tint).
    var skinsMenuProvider: (() -> NSMenu)?
    let log = Log.logger("ui")

    // Menus
    /// The menu tracking right now, what it is, and where it came from.
    var openMenu: NSMenu?
    var openMenuKind: String?
    var openMenuAnchor: GenreMenuAnchor?
    var pendingPopUp: (menu: NSMenu, point: CGPoint, kind: String, anchor: GenreMenuAnchor?)?
    /// Menus whose `popUp` hasn't returned yet (a cancelled one unwinds on the next run-loop turn).
    var trackingDepth = 0
    var hoverTask: Task<Void, Never>?
    var menuWatchdog: Task<Void, Never>?
    private(set) var menuAutoOpened = false
    /// Menu choices made through a menu, for the automation report.
    var menuSelections: [[String: String]] = []
    var menuDumps: [[String: Any]] = []
    /// Every menu automation saw open: its anchor and the genre menu it showed (the context menu's `Genre ▸`).
    var openedMenus: [[String: Any]] = []
    /// The file Load/Save .eqf… uses instead of a panel (automation).
    var injectedEQFURL: URL?

    // Sheets
    private(set) var lastSheet: String?
    private(set) var sheetOpen = false

    init(context: AppContext, automation: Bool) {
        self.context = context
        isAutomation = automation
        super.init()
    }

    // MARK: What the front ends provide

    /// The window sheets attach to.
    var sheetWindow: NSWindow? { nil }
    /// Where the genre menu opens "under the marquee": the top-left of the menu, in screen coordinates.
    func genreMenuAnchorPoint() -> CGPoint { .zero }
    /// Where the presets menu opens (automation's Load/Save .eqf…).
    func presetsMenuAnchorPoint() -> CGPoint { .zero }
    /// The View menu's items (menu bar and context menu).
    @objc dynamic func viewItems() -> [NSMenuItem] { [] }
    /// Redraw from the controller's snapshot.
    func render(_ s: PlayerSnapshot? = nil) {}
    func publishDebugState() {}
    /// The skin About credits.
    var aboutSkin: SkinEntry? { nil }

    // MARK: Opening

    /// The genre menu at an anchor: under the marquee or genre button (DESIGN §3), or at `point`.
    func openGenreMenu(_ anchor: GenreMenuAnchor, at point: CGPoint? = nil) {
        let menu = genreMenu()
        popUp(menu, at: point ?? genreMenuAnchorPoint(), kind: "genre", anchor: anchor)
    }

    /// Pops `menu` up at `point` from the next run-loop turn (see the type's note), replacing an open one.
    func popUp(_ menu: NSMenu, at point: CGPoint, kind: String, anchor: GenreMenuAnchor?) {
        guard !context.isShutDown else { return }
        if openMenu != nil || pendingPopUp != nil { cancelMenuTracking() }
        pendingPopUp = (menu, point, kind, anchor)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(popUpPending), object: nil)
        perform(#selector(popUpPending), with: nil, afterDelay: 0, inModes: [.common])
    }

    @objc private func popUpPending() {
        guard let pending = pendingPopUp else { return }
        // A cancelled menu's tracking loop unwinds on its next turn; never nest a new menu inside it.
        if trackingDepth > 0 {
            perform(#selector(popUpPending), with: nil, afterDelay: 0.02, inModes: [.common])
            return
        }
        pendingPopUp = nil
        track(pending.menu, at: pending.point, kind: pending.kind, anchor: pending.anchor)
    }

    private func track(_ menu: NSMenu, at point: CGPoint, kind: String, anchor: GenreMenuAnchor?) {
        guard !context.isShutDown, openMenu == nil, trackingDepth == 0 else { return }
        trackingDepth += 1
        defer { trackingDepth -= 1 }
        openMenu = menu
        openMenuKind = kind
        openMenuAnchor = anchor
        if menu.delegate == nil { menu.delegate = self }
        if anchor == .auto { markMenuAutoOpened() }
        if isAutomation { recordOpened(menu, kind: kind, anchor: anchor) }
        publishDebugState()
        armMenuWatchdog()
        menu.popUp(positioning: nil, at: point, in: nil)
        // popUp returns once the menu has closed.
        if openMenu === menu { menuClosed() }
    }

    private func recordOpened(_ menu: NSMenu, kind: String, anchor: GenreMenuAnchor?) {
        var entry: [String: Any] = ["kind": kind, "anchor": anchor?.rawValue ?? kind]
        let genre = kind == "genre" ? menu : menu.items.first { $0.title == "Genre" }?.submenu
        if let genre { entry["genreMenu"] = Self.json(MenuDump.genreNodes(genre)) }
        openedMenus.append(entry)
    }

    /// First launch (DESIGN §3): the genre menu opens by itself once, after the windows have settled.
    func openGenreMenuSoon() {
        perform(#selector(autoOpenGenreMenu), with: nil, afterDelay: 0.5, inModes: [.common])
    }

    @objc private func autoOpenGenreMenu() {
        guard !context.isShutDown, openMenu == nil else { return }
        context.markGenreMenuShown()
        track(genreMenu(), at: genreMenuAnchorPoint(), kind: "genre", anchor: .auto)
    }

    /// Play with nothing chosen yet means "pick a genre".
    func pickGenre() { openGenreMenu(.marquee) }

    func cancelMenuTracking() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(autoOpenGenreMenu), object: nil)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(popUpPending), object: nil)
        pendingPopUp = nil
        guard let menu = openMenu else { return }
        menu.cancelTrackingWithoutAnimation()
        // It is closing: what is open from now on is whatever opens next.
        menuClosed()
    }

    /// A menu opened by automation never stays up for long: an unattended open menu would hold the owner's mouse
    /// and keyboard.
    private func armMenuWatchdog() {
        menuWatchdog?.cancel()
        guard isAutomation else { return }
        menuWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.openMenu != nil else { return }
            self.log.notice("automation: closing a menu left open for 15 s")
            self.cancelMenuTracking()
        }
    }

    func menuClosed() {
        openMenu = nil
        openMenuKind = nil
        openMenuAnchor = nil
        hoverTask?.cancel()
        menuWatchdog?.cancel()
        publishDebugState()
    }

    func markMenuAutoOpened() {
        menuAutoOpened = true
        publishDebugState()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        if menu.title == "Genre" { context.refreshAvailability() }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === openMenu else { return }
        // The chosen item's action runs after this; let it, then forget the menu.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.openMenu === menu else { return }
            self.menuClosed()
        }
    }

    /// DESIGN §3: hovering a genre for 300 ms pre-resolves its next pick.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        hoverTask?.cancel()
        guard let item, case .genre(let g)? = GenreMenuChoice(item), item.isEnabled else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.context.controller.preresolve(genre: g)
        }
    }

    // MARK: Genre menu

    func genreMenu() -> NSMenu {
        GenreMenuBuilder.menu(context.genreMenuContent(shortcuts: false), target: self,
                              action: #selector(genreChosen(_:)), delegate: self)
    }

    @objc func genreChosen(_ sender: NSMenuItem) {
        guard let choice = GenreMenuChoice(sender) else { return }
        recordSelection(menu: "genre", item: sender.title, choice: choice)
        context.perform(choice, origin: "skin.\(openMenuAnchor?.rawValue ?? "menu")")
    }

    func recordSelection(menu: String, item: String, choice: GenreMenuChoice? = nil) {
        var entry = ["menu": menu, "item": item, "anchor": openMenuAnchor?.rawValue ?? "-"]
        if case .genre(let g)? = choice { entry["genre"] = g.rawValue }
        if let choice { entry["choice"] = choice.tag }
        menuSelections.append(entry)
    }

    // MARK: Context menu (right-click, clutter O, the modern ⋯ button)

    func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "sudamp")
        menu.autoenablesItems = false
        menu.delegate = self
        let genre = NSMenuItem(title: "Genre", action: nil, keyEquivalent: "")
        genre.submenu = genreMenu()
        menu.addItem(genre)
        menu.addItem(.separator())
        let s = context.controller.snapshot
        let playing = [.playing, .tuning, .buffering].contains(s.phase)
        add(menu, playing ? "Pause" : "Play", #selector(contextTogglePlay(_:)), key: playing ? "c" : "x", modifiers: [])
        add(menu, "Stop", #selector(contextStop(_:)), key: "v", modifiers: [])
        add(menu, "Next Stream", #selector(contextNext(_:)), key: "b", modifiers: [])
        add(menu, "Previous Stream", #selector(contextPrevious(_:)), key: "z", modifiers: [])
        menu.addItem(.separator())
        let favourite = add(menu, "Favourite", #selector(contextFavourite(_:)), key: "f")
        favourite.state = s.isFavourite ? .on : .off
        favourite.isEnabled = s.stream != nil
        add(menu, "Never Play This", #selector(contextBan(_:)), key: "\u{8}").isEnabled = s.stream != nil
        add(menu, "Copy Link", #selector(contextCopyLink(_:)), key: "c", modifiers: [.command, .option]).isEnabled = s.stream != nil
        add(menu, "Open Stream URL…", #selector(contextOpenURL(_:)), key: "l")
        menu.addItem(.separator())
        let skins = NSMenuItem(title: "Skins", action: nil, keyEquivalent: "")
        skins.submenu = skinsMenuProvider?() ?? NSMenu(title: "Skins")
        menu.addItem(skins)
        for item in viewItems() { menu.addItem(item) }
        menu.addItem(.separator())
        add(menu, "About sudamp", #selector(contextAbout(_:)))
        add(menu, "Quit sudamp", #selector(contextQuit(_:)), key: "q")
        return menu
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
             modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = self
        return item
    }

    @objc func contextTogglePlay(_ sender: Any?) { context.perform(.toggle, origin: "context") }
    @objc func contextStop(_ sender: Any?) { context.perform(.stop, origin: "context") }
    @objc func contextNext(_ sender: Any?) { context.perform(.next, origin: "context") }
    @objc func contextPrevious(_ sender: Any?) { context.perform(.previous, origin: "context") }
    @objc func contextFavourite(_ sender: Any?) { context.toggleFavourite() }
    @objc func contextBan(_ sender: Any?) { context.banCurrent() }
    @objc func contextCopyLink(_ sender: Any?) { context.copyLink() }
    @objc func contextOpenURL(_ sender: Any?) { promptForStreamURL() }
    @objc func contextAbout(_ sender: Any?) { AppMenus.showAbout(skin: aboutSkin) }
    @objc func contextQuit(_ sender: Any?) { context.perform(.quit, origin: "context") }

    @objc func unbanChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = StreamID(rawValue: raw) else { return }
        context.unban(id)
    }

    func promptForStreamURL() {
        StreamURLPrompt.run(context: context, window: sheetWindow, automation: isAutomation)
    }

    func syncVolume() { render() }

    // MARK: Visualiser and stream info (clutter V and I)

    func visualizerMenu() -> NSMenu {
        let menu = NSMenu(title: "Visualizer")
        menu.autoenablesItems = false
        let current = SkinPrefs(context.settings).visualizer
        for (title, mode) in [("Spectrum Analyzer", VisualizerFrame.Mode.spectrum), ("Oscilloscope", .oscilloscope),
                              ("Off", .off)] {
            let item = add(menu, title, #selector(visualizerChosen(_:)))
            item.representedObject = SkinPrefs.name(mode)
            item.state = mode == current ? .on : .off
        }
        return menu
    }

    @objc func visualizerChosen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        setVisualizer(SkinPrefs.mode(name))
    }

    func setVisualizer(_ mode: VisualizerFrame.Mode) {
        context.updateSettings { $0.visualizer = SkinPrefs.name(mode) }
        render()
        publishDebugState()
    }

    /// Spectrum → oscilloscope → off → spectrum (a click on the visualiser).
    func cycleVisualizer() {
        let next: VisualizerFrame.Mode = switch SkinPrefs(context.settings).visualizer {
        case .spectrum: .oscilloscope
        case .oscilloscope: .off
        case .off: .spectrum
        }
        setVisualizer(next)
    }

    func streamInfoMenu() -> NSMenu {
        let menu = NSMenu(title: "Stream")
        menu.autoenablesItems = false
        let s = context.controller.snapshot
        guard let stream = s.stream else {
            menu.addItem(withTitle: "Nothing is playing", action: nil, keyEquivalent: "").isEnabled = false
            return menu
        }
        menu.addItem(withTitle: "\(stream.creator) - \(stream.title)", action: nil, keyEquivalent: "").isEnabled = false
        var detail = PlainDisplay.sourceName(stream.source)
        if let name = s.genreName { detail += " · \(name)" }
        if let kbps = s.audioFormat?.kbps { detail += " · \(kbps) kbps" }
        menu.addItem(withTitle: detail, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        add(menu, "Copy Link", #selector(contextCopyLink(_:)), key: "c", modifiers: [.command, .option])
        if stream.link != nil { add(menu, "Open in Browser", #selector(openInBrowser(_:))) }
        add(menu, s.isFavourite ? "Remove from Favourites" : "Add to Favourites", #selector(contextFavourite(_:)), key: "f")
        return menu
    }

    @objc func openInBrowser(_ sender: Any?) {
        let s = context.controller.snapshot
        guard let stream = s.stream, let link = CopyLink.link(for: stream, position: s.position) else { return }
        NSWorkspace.shared.open(link.url)
    }

    // MARK: EQ presets (17 presets + Load/Save .eqf, PLAN M5)

    func presetsMenu() -> NSMenu {
        let menu = NSMenu(title: "Presets")
        menu.autoenablesItems = false
        menu.delegate = self
        let current = context.settings.eqPreset
        func presetItem(_ preset: EQPreset, user: Bool) {
            let item = add(menu, preset.name, #selector(presetChosen(_:)))
            item.representedObject = (user ? "user:" : "builtin:") + preset.name
            item.state = preset.name == current ? .on : .off
        }
        presetItem(EQPresets.flat, user: false)
        menu.addItem(.separator())
        for preset in EQPresets.builtIn { presetItem(preset, user: false) }
        let user = context.settings.userPresets
        if !user.isEmpty {
            menu.addItem(.separator())
            for preset in user { presetItem(preset, user: true) }
        }
        menu.addItem(.separator())
        add(menu, "Load .eqf…", #selector(loadEQF(_:)))
        add(menu, "Save .eqf…", #selector(saveEQF(_:)))
        return menu
    }

    @objc func presetChosen(_ sender: NSMenuItem) {
        guard let tag = sender.representedObject as? String else { return }
        let name = String(tag.drop { $0 != ":" }.dropFirst())
        let preset = tag.hasPrefix("user:") ? context.settings.userPresets.first { $0.name == name } : EQPresets.named(name)
        guard let preset else { return }
        recordSelection(menu: "presets", item: preset.name)
        applyPreset(preset)
    }

    func applyPreset(_ preset: EQPreset) {
        let enabled = context.controller.equalizer.enabled
        context.setEqualizer(preset.settings(enabled: enabled), preset: preset.name)
        render()
        publishDebugState()
    }

    /// Loads every preset of a Winamp `.eqf` library: they join the user presets and the first is applied.
    @objc func loadEQF(_ sender: Any?) {
        recordSelection(menu: "presets", item: "Load .eqf…")
        guard let url = injectedEQFURL ?? eqfPanel(save: false) else { return }
        injectedEQFURL = nil
        do {
            let presets = try EQF.decode(try Data(contentsOf: url))
            guard let first = presets.first else { throw EQF.DecodeError.noPresets }
            context.updateSettings { s in for p in presets { s.addUserPreset(p) } }
            applyPreset(first)
            log.info("loaded \(presets.count) preset(s) from \(url.lastPathComponent, privacy: .public)")
        } catch {
            log.notice("cannot load \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            context.controller.noteShellError(kind: "eqfRejected", message: "\(url.lastPathComponent): \(error)", stage: "eqf")
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” is not a Winamp EQ file"
            alert.informativeText = "sudamp reads .eqf preset libraries (Winamp EQ library file v1.1)."
            alert.addButton(withTitle: "OK")
            showSheet(alert, name: "eqfRejected")
        }
    }

    /// Saves the current EQ as a one-entry `.eqf`, named after the file.
    @objc func saveEQF(_ sender: Any?) {
        recordSelection(menu: "presets", item: "Save .eqf…")
        guard let url = injectedEQFURL ?? eqfPanel(save: true) else { return }
        injectedEQFURL = nil
        let name = context.settings.eqPreset ?? url.deletingPathExtension().lastPathComponent
        let preset = EQPreset(name: name, settings: context.controller.equalizer)
        do {
            try EQF.encode(preset).write(to: url, options: .atomic)
            log.info("saved preset \(name, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
        } catch {
            context.controller.noteShellError(kind: "eqfWriteFailed", message: "\(url.path): \(error)", stage: "eqf")
        }
    }

    private func eqfPanel(save: Bool) -> URL? {
        guard !isAutomation else { return nil }
        NSApp.activate()
        if save {
            let panel = NSSavePanel()
            panel.title = "Save EQ Preset"
            panel.nameFieldStringValue = (context.settings.eqPreset ?? "sudamp") + ".eqf"
            panel.allowsOtherFileTypes = true
            return panel.runModal() == .OK ? panel.url : nil
        }
        let panel = NSOpenPanel()
        panel.title = "Load EQ Presets"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.delegate = self
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Open panels list folders, skin archives and EQ files only.
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.hasDirectoryPath || SkinView.isSkinFile(url) || ["eqf", "q1"].contains(url.pathExtension.lowercased())
    }

    // MARK: Sheets

    /// A window-modal sheet on the main window (shown even while it is off screen under automation, then dismissed).
    func showSheet(_ alert: NSAlert, name: String) {
        lastSheet = name
        guard let main = sheetWindow else { return }
        if let sheet = main.attachedSheet { main.endSheet(sheet) }
        sheetOpen = true
        alert.beginSheetModal(for: main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sheetOpen = false
                self?.publishDebugState()
            }
        }
        publishDebugState()
        if isAutomation {
            Task { @MainActor [weak self, weak main] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let main, let sheet = main.attachedSheet else { return }
                main.endSheet(sheet)
                self?.publishDebugState()
            }
        }
    }

    /// A refused skin archive (DESIGN §8.2): the current skin stays; `.lastError.kind == "skinRejected"`; a
    /// window-modal sheet says why (dismissed by itself under `--automation`).
    func reject(_ rejection: SkinRejection, origin: String) {
        log.notice("skin rejected (\(origin, privacy: .public)): \(rejection.file, privacy: .public): \(rejection.reason, privacy: .public)")
        context.controller.noteShellError(kind: "skinRejected", message: "\(rejection.file): \(rejection.reason): \(rejection.message)",
                                          stage: "skin")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(rejection.file)” can't be used as a skin"
        alert.informativeText = rejection.message + " The current skin stays."
        alert.addButton(withTitle: "OK")
        showSheet(alert, name: "skinRejected")
    }

    // MARK: Automation through menus

    /// `selectGenre` / `surpriseMe` go through the genre menu, as a click would.
    func automationSelect(_ choice: GenreMenuChoice) async -> (Bool, String?) {
        if openMenuKind != "genre" {
            openGenreMenu(.marquee)
            guard await waitForMenu(.genre, timeout: 3) else { return (false, "the genre menu did not open") }
        }
        return choose(where: { GenreMenuChoice($0) == choice }, describe: choice.tag)
    }

    func automationWillStart(firstLaunch: Bool) {
        // The first-launch auto-open is the app's own launch behaviour; under automation it runs only when the
        // script waits for it (`waitForMenu auto`), so no other script leaves a menu on the owner's screen.
        if firstLaunch { openGenreMenuSoon() }
    }

    /// The report's menu parts (the front ends add their own keys).
    var menuReport: [String: Any] {
        var report: [String: Any] = ["menuAutoOpened": menuAutoOpened, "menuSelections": menuSelections]
        if !menuDumps.isEmpty { report["menus"] = menuDumps }
        if !openedMenus.isEmpty { report["openedMenus"] = openedMenus }
        return report
    }

    /// The steps both skin classes run the same way; nil for one the front end must handle.
    func performMenuStep(_ step: ShellAutomationScript.SkinStep) async -> (Bool, String?)? {
        switch step {
        case .openGenreMenu(let anchor):
            switch anchor {
            case .contextMenu:
                popUp(contextMenu(), at: genreMenuAnchorPoint(), kind: "context", anchor: .contextMenu)
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
        case .dumpMenus(let label):
            menuDumps.append(dumpMenus(label: label))
            return (true, nil)
        case .saveEQF(let path), .loadEQF(let path):
            let save: Bool = if case .saveEQF = step { true } else { false }
            injectedEQFURL = URL(filePath: (path as NSString).expandingTildeInPath)
            popUp(presetsMenu(), at: presetsMenuAnchorPoint(), kind: "presets", anchor: nil)
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
        case .pressControl, .dragSlider, .loadSkin, .showWindows, .playRow:
            return nil
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
    func choose(path: String) -> (Bool, String?) {
        guard let menu = openMenu else { return (false, "no menu is open") }
        guard let item = MenuDump.find(path, in: menu) else { return (false, "no item \(path) in the \(openMenuKind ?? "") menu") }
        return select(item, in: menu, describe: path)
    }

    func choose(where predicate: (NSMenuItem) -> Bool, describe: String) -> (Bool, String?) {
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
            "skinsMenu": Self.json(MenuDump.nodes(skinsMenuProvider?() ?? NSMenu())),
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
