// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Catalog
import Core
import Playback

/// The menu bar, the status item and the Dock menu (PLAN M2 "Shell basics", M5 "Library and keys"). Genre rows come
/// from `GenreMenuBuilder` (the same menu every anchor shows); every action goes to `AppContext`, and the skinned
/// UI's View and Skins menus to `SkinnedPlayerUI`.
///
/// Winamp's single-letter keys (X C V B Z, S R) are menu key equivalents; while a text field has the keyboard (the
/// Open Stream URL prompt) they are disabled, so typing reaches the field.
final class AppMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let context: AppContext
    private let genreMenu = NSMenu(title: "Genre")
    private let statusMenu = NSMenu(title: "sudamp")
    private let viewMenu = NSMenu(title: "View")
    private let skinsMenu = NSMenu(title: "Skins")
    private let favouritesMenu = NSMenu(title: "Favourite Streams")
    private let bannedMenu = NSMenu(title: "Recently Banned")
    private var statusItem: NSStatusItem?
    /// The skinned front end (nil with `--plain`): View and Skins menus.
    weak var skinned: SkinnedPlayerUI?
    /// The front end, for Open Stream URL….
    weak var frontEnd: (any PlayerFrontEnd)?
    /// Called after a volume shortcut (the window's slider follows).
    var onVolumeChanged: (() -> Void)?

    init(context: AppContext) {
        self.context = context
        super.init()
        for menu in [genreMenu, statusMenu, viewMenu, skinsMenu, favouritesMenu, bannedMenu] {
            menu.delegate = self
            menu.autoenablesItems = false
        }
    }

    // MARK: Menu bar

    /// sudamp, File, Edit, Genre (⌘1–⌘9, ⌘0 Surprise Me), Controls, View and Skins (skinned), Window.
    func installMainMenu(skinned: Bool) {
        let main = NSMenu()

        let app = NSMenu(title: "sudamp")
        app.addItem(withTitle: "About sudamp", action: #selector(showAbout(_:)), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide sudamp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                                 keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit sudamp", action: #selector(quit(_:)), keyEquivalent: "q").target = self
        main.addItem(submenu(app, title: "sudamp"))

        let file = NSMenu(title: "File")
        file.autoenablesItems = true
        add(file, "Open Stream URL…", #selector(openStreamURL(_:)), key: "l")
        if skinned { add(file, "Open Skin…", #selector(openSkin(_:)), key: "o", modifiers: [.command, .shift]) }
        file.addItem(.separator())
        add(file, "Copy Link", #selector(copyLink(_:)), key: "c", modifiers: [.command, .option])
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        // Standard editing, so the URL prompt's field can paste (and Undo reaches "Never Play This").
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        rebuildGenreMenu()
        main.addItem(submenu(genreMenu, title: "Genre"))

        let controls = NSMenu(title: "Controls")
        controls.autoenablesItems = true
        // Winamp's keys (DESIGN §3): X play, C pause, V stop, B next, Z previous.
        for (title, key, selector) in [
            ("Play", "x", #selector(play(_:))), ("Pause", "c", #selector(pause(_:))), ("Stop", "v", #selector(stop(_:))),
            ("Next Stream", "b", #selector(next(_:))), ("Previous Stream", "z", #selector(previous(_:))),
        ] as [(String, String, Selector)] {
            add(controls, title, selector, key: key, modifiers: [])
        }
        controls.addItem(.separator())
        add(controls, "Volume Up", #selector(volumeUp(_:)), key: Self.functionKey(NSUpArrowFunctionKey))
        add(controls, "Volume Down", #selector(volumeDown(_:)), key: Self.functionKey(NSDownArrowFunctionKey))
        controls.addItem(.separator())
        add(controls, "Shuffle Genres", #selector(toggleShuffle(_:)), key: "s", modifiers: [])
        add(controls, "Repeat", #selector(toggleRepeat(_:)), key: "r", modifiers: [])
        controls.addItem(.separator())
        add(controls, "Favourite", #selector(favourite(_:)), key: "f")
        add(controls, "Never Play This", #selector(ban(_:)), key: "\u{8}")
        controls.addItem(submenu(favouritesMenu, title: "Favourite Streams"))
        controls.addItem(submenu(bannedMenu, title: "Recently Banned"))
        controls.addItem(.separator())
        add(controls, "Retry", #selector(retry(_:)), key: "r")
        main.addItem(submenu(controls, title: "Controls"))

        if skinned {
            rebuildViewMenu()
            main.addItem(submenu(viewMenu, title: "View"))
            rebuildSkinsMenu()
            main.addItem(submenu(skinsMenu, title: "Skins"))
        }

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: "Player", action: #selector(show(_:)), keyEquivalent: "").target = self
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
        context.observeAvailability { [weak self] in self?.rebuildGenreMenu() }
    }

    private static func functionKey(_ key: Int) -> String { String(utf16CodeUnits: [unichar(key)], count: 1) }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                     modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = self
        return item
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func rebuildGenreMenu() {
        GenreMenuBuilder.fill(genreMenu, with: context.genreMenuContent(shortcuts: true), target: self,
                              action: #selector(genreChosen(_:)), shortcuts: true)
    }

    private func rebuildViewMenu() {
        viewMenu.removeAllItems()
        for item in skinned?.viewItems() ?? [] { viewMenu.addItem(item) }
    }

    private func rebuildSkinsMenu() {
        skinsMenu.removeAllItems()
        guard let skins = skinned?.skinsMenu() else { return }
        let items = skins.items
        skins.removeAllItems()
        for item in items { skinsMenu.addItem(item) }
    }

    private func rebuildFavouritesMenu() {
        favouritesMenu.removeAllItems()
        let favourites = context.controller.favouriteStreams
        if favourites.isEmpty {
            favouritesMenu.addItem(withTitle: GenreMenuContent.noFavourites, action: nil, keyEquivalent: "").isEnabled = false
        }
        for s in favourites {
            let row = GenreMenuContent.streamRow(s)
            let item = add(favouritesMenu, "\(row.title)  [\(row.tag)]", #selector(genreChosen(_:)))
            item.representedObject = GenreMenuChoice.stream(s.id).tag
        }
    }

    /// Recently Banned ▸: choosing one lets it back in.
    static func recentlyBannedMenu(context: AppContext, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Recently Banned")
        menu.autoenablesItems = false
        fillBanned(menu, context: context, target: target, action: action)
        return menu
    }

    private static func fillBanned(_ menu: NSMenu, context: AppContext, target: AnyObject, action: Selector) {
        menu.removeAllItems()
        let banned = context.controller.recentlyBanned(limit: 10)
        if banned.isEmpty { menu.addItem(withTitle: "Nothing banned", action: nil, keyEquivalent: "").isEnabled = false }
        for s in banned {
            let row = GenreMenuContent.streamRow(s)
            let item = menu.addItem(withTitle: "Play Again: \(row.title)  [\(row.tag)]", action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = s.id.rawValue
        }
    }

    // MARK: Status item

    /// A small status-item menu: what plays, the genre menu, Play/Pause, Next, Show, Quit.
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "sudamp")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "sudamp"
        item.menu = statusMenu
        statusItem = item
        fillStatusMenu(statusMenu)
    }

    private func fillStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = context.controller.snapshot
        let display = PlainDisplay(s, muted: context.muted)
        menu.addItem(withTitle: display.title, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: display.status, action: nil, keyEquivalent: "").isEnabled = false
        if let notice = display.engineNotice {
            menu.addItem(withTitle: notice, action: nil, keyEquivalent: "").isEnabled = false
        }
        menu.addItem(.separator())
        for item in GenreMenuBuilder.items(context.genreMenuContent(shortcuts: false), target: self,
                                           action: #selector(genreChosen(_:)), shortcuts: false) {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, display.showsPause ? "Pause" : "Play", #selector(togglePlay(_:)))
        add(menu, "Next Stream", #selector(next(_:)))
        menu.addItem(.separator())
        add(menu, "Show Player", #selector(show(_:)))
        add(menu, "Quit sudamp", #selector(quit(_:)))
    }

    // MARK: Dock

    /// The Dock menu: the genre menu, Play/Pause, Next (DESIGN §3).
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in GenreMenuBuilder.items(context.genreMenuContent(shortcuts: false), target: self,
                                           action: #selector(genreChosen(_:)), shortcuts: false) {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let showsPause = PlainDisplay(context.controller.snapshot).showsPause
        add(menu, showsPause ? "Pause" : "Play", #selector(togglePlay(_:)))
        add(menu, "Next Stream", #selector(next(_:)))
        return menu
    }

    // MARK: Menus dump (automation)

    func genreMenuForDump() -> NSMenu {
        rebuildGenreMenu()
        return genreMenu
    }

    func statusMenuForDump() -> NSMenu {
        let menu = NSMenu(title: "sudamp")
        menu.autoenablesItems = false
        fillStatusMenu(menu)
        return menu
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            fillStatusMenu(statusMenu)
        } else if menu === genreMenu {
            rebuildGenreMenu()
        } else if menu === viewMenu {
            rebuildViewMenu()
        } else if menu === skinsMenu {
            rebuildSkinsMenu()
        } else if menu === favouritesMenu {
            rebuildFavouritesMenu()
        } else if menu === bannedMenu {
            Self.fillBanned(bannedMenu, context: context, target: self, action: #selector(unbanChosen(_:)))
        }
    }

    func menuWillOpen(_ menu: NSMenu) { context.refreshAvailability() }

    /// DESIGN §3: hovering a genre for 300 ms pre-resolves its next pick (menu bar, status item).
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        hoverTask?.cancel()
        guard let item, case .genre(let g)? = GenreMenuChoice(item), item.isEnabled else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.context.controller.preresolve(genre: g)
        }
    }

    private var hoverTask: Task<Void, Never>?

    // MARK: Validation

    /// Single-letter shortcuts give way to a text field; library items need something playing.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.keyEquivalentModifierMask.isEmpty, !item.keyEquivalent.isEmpty,
           NSApp.keyWindow?.firstResponder is NSText {
            return false
        }
        let s = context.controller.snapshot
        switch item.action {
        case #selector(favourite(_:)):
            item.state = s.isFavourite ? .on : .off
            item.title = s.isFavourite ? "Remove from Favourites" : "Favourite"
            return s.stream != nil
        case #selector(ban(_:)), #selector(copyLink(_:)):
            return s.stream != nil
        case #selector(toggleShuffle(_:)):
            item.state = s.shuffleGenres ? .on : .off
            return true
        case #selector(toggleRepeat(_:)):
            item.state = s.repeatStream ? .on : .off
            return true
        case #selector(retry(_:)):
            return s.phase == .failed || s.engine.state == .failed
        default:
            return true
        }
    }

    // MARK: Actions

    @objc private func genreChosen(_ sender: NSMenuItem) {
        guard let choice = GenreMenuChoice(sender) else { return }
        context.perform(choice, origin: "menu")
    }

    @objc private func unbanChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = StreamID(rawValue: raw) else { return }
        context.unban(id)
    }

    @objc private func play(_ sender: Any?) { context.perform(.play, origin: "menu") }
    @objc private func pause(_ sender: Any?) {
        // Winamp's pause toggles.
        context.perform(context.controller.phase == .paused ? .play : .pause, origin: "menu")
    }
    @objc private func stop(_ sender: Any?) { context.perform(.stop, origin: "menu") }
    @objc private func next(_ sender: Any?) { context.perform(.next, origin: "menu") }
    @objc private func previous(_ sender: Any?) { context.perform(.previous, origin: "menu") }
    @objc private func togglePlay(_ sender: Any?) { context.perform(.toggle, origin: "menu") }
    @objc private func retry(_ sender: Any?) { context.retry() }
    @objc private func show(_ sender: Any?) { context.perform(.show, origin: "menu") }
    @objc private func quit(_ sender: Any?) { context.perform(.quit, origin: "menu") }
    @objc private func toggleShuffle(_ sender: Any?) {
        context.toggleShuffle()
        skinned?.render()
    }
    @objc private func toggleRepeat(_ sender: Any?) {
        context.toggleRepeat()
        skinned?.render()
    }
    @objc private func favourite(_ sender: Any?) { context.toggleFavourite() }
    @objc private func ban(_ sender: Any?) { context.banCurrent() }
    @objc private func copyLink(_ sender: Any?) { context.copyLink() }
    @objc private func openStreamURL(_ sender: Any?) { frontEnd?.promptForStreamURL() }
    @objc private func openSkin(_ sender: Any?) { skinned?.openSkinPanel() }

    @objc private func volumeUp(_ sender: Any?) { nudgeVolume(+10) }
    @objc private func volumeDown(_ sender: Any?) { nudgeVolume(-10) }

    private func nudgeVolume(_ delta: Double) {
        context.setVolume(context.settings.volume + delta)
        onVolumeChanged?()
    }

    @objc private func showAbout(_ sender: Any?) { Self.showAbout(skin: skinned?.skinEntry) }

    /// About: the native About window (AboutWindow.swift): stance, licence, credits, the current skin's credit and
    /// viewers for LICENSE, CREDITS.md and THIRD_PARTY_NOTICES.md.
    static func showAbout(skin: SkinEntry?) { AboutWindow.show(skin: skin) }
}
