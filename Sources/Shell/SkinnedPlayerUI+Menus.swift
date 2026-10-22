// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Audio
import Catalog
import Playback
import SkinKit
import SkinUI

/// The skinned UI's pop-up menus: the genre menu (every anchor, the same builder), the right-click context menu,
/// the EQ presets menu with Load/Save .eqf…, the visualiser and stream-info menus, and the playlist's buttons.
///
/// Every menu pops up from a zero-delay run-loop perform in the common modes, whoever asked (a click, a key, the
/// first-launch auto-open, automation): `NSMenu.popUp` runs a nested tracking loop, and from inside a main-queue job
/// (every main-actor task is one) that loop could not run main-actor work (M2 finding), so hover pre-resolve and
/// automation would stall until the menu closed.
extension SkinnedPlayerUI: NSMenuDelegate {
    // MARK: Opening

    /// The genre menu at an anchor: under the marquee (DESIGN §3), or at `point` (the playlist's LIST button).
    func openGenreMenu(_ anchor: GenreMenuAnchor, at point: CGPoint? = nil) {
        let menu = genreMenu()
        popUp(menu, at: point ?? manager.marqueeMenuAnchor(), kind: "genre", anchor: anchor)
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
        track(genreMenu(), at: manager.marqueeMenuAnchor(), kind: "genre", anchor: .auto)
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

    // MARK: Context menu (right-click, clutter O)

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
        skins.submenu = skinsMenu()
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

    @objc private func contextTogglePlay(_ sender: Any?) { context.perform(.toggle, origin: "context") }
    @objc private func contextStop(_ sender: Any?) { context.perform(.stop, origin: "context") }
    @objc private func contextNext(_ sender: Any?) { context.perform(.next, origin: "context") }
    @objc private func contextPrevious(_ sender: Any?) { context.perform(.previous, origin: "context") }
    @objc private func contextFavourite(_ sender: Any?) { context.toggleFavourite() }
    @objc private func contextBan(_ sender: Any?) { context.banCurrent() }
    @objc private func contextCopyLink(_ sender: Any?) { context.copyLink() }
    @objc private func contextOpenURL(_ sender: Any?) { promptForStreamURL() }
    @objc private func contextAbout(_ sender: Any?) { AppMenus.showAbout(skin: skinEntry) }
    @objc private func contextQuit(_ sender: Any?) { context.perform(.quit, origin: "context") }

    // MARK: Skins and View (shared by the context menu and the menu bar)

    func skinsMenu() -> NSMenu {
        let menu = NSMenu(title: "Skins")
        menu.autoenablesItems = false
        var origin: SkinEntry.Origin?
        for entry in library.entries() {
            if let origin, origin != entry.origin { menu.addItem(.separator()) }
            origin = entry.origin
            let item = add(menu, entry.name, #selector(skinChosen(_:)))
            item.representedObject = entry.id
            item.state = entry.id == skinEntry.id ? .on : .off
            if let credit = entry.credit {
                item.toolTip = credit
                item.subtitle = credit
            }
        }
        menu.addItem(.separator())
        add(menu, "Open Skin…", #selector(openSkin(_:)), key: "o", modifiers: [.command, .shift])
        add(menu, "Show Skins Folder", #selector(showSkinsFolder(_:)))
        add(menu, "Get More Skins…", #selector(getMoreSkins(_:)))
        return menu
    }

    @objc func skinChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        recordSelection(menu: "skins", item: sender.title)
        _ = selectSkin(id: id, origin: "menu")
    }

    @objc func openSkin(_ sender: Any?) { openSkinPanel() }

    @objc func showSkinsFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: context.paths.skins, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([context.paths.skins])
    }

    /// DESIGN §8.3: third-party skins arrive only by user action ("Get more skins…" opens skins.webamp.org).
    @objc func getMoreSkins(_ sender: Any?) {
        if let url = URL(string: "https://skins.webamp.org/") { NSWorkspace.shared.open(url) }
    }

    /// Double Size, scales, Always on Top, the windows, shade, time, visualiser, font, region shaping.
    func viewItems() -> [NSMenuItem] {
        let holder = NSMenu()
        let double = add(holder, "Double Size", #selector(viewToggleScale(_:)), key: "d")
        double.state = manager.scale >= 2 ? .on : .off
        for scale in SkinScale.allowed {
            let item = add(holder, "Scale \(scale)x", #selector(viewSetScale(_:)), key: "\(scale)", modifiers: [.command, .option])
            item.tag = scale
            item.state = manager.scale == scale ? .on : .off
        }
        add(holder, "Always on Top", #selector(viewAlwaysOnTop(_:)), key: "a", modifiers: [.command, .option]).state =
            manager.alwaysOnTop ? .on : .off
        holder.addItem(.separator())
        add(holder, "Equalizer", #selector(viewToggleEqualizer(_:)), key: "g", modifiers: [.command, .option]).state =
            manager.isOpen(.equalizer) ? .on : .off
        add(holder, "Playlist", #selector(viewTogglePlaylist(_:)), key: "e", modifiers: [.command, .option]).state =
            manager.isOpen(.playlist) ? .on : .off
        add(holder, "Window Shade", #selector(viewToggleShade(_:)), key: "w", modifiers: [.command, .option]).state =
            manager.isShaded(.main) ? .on : .off
        add(holder, "Regroup Windows", #selector(viewRegroup(_:)))
        holder.addItem(.separator())
        add(holder, "Time Remaining", #selector(viewTimeRemaining(_:))).state = context.settings.timeRemaining ? .on : .off
        let vis = NSMenuItem(title: "Visualizer", action: nil, keyEquivalent: "")
        vis.submenu = visualizerMenu()
        holder.addItem(vis)
        add(holder, "Always Use Skin Font", #selector(viewSkinFont(_:))).state = context.settings.alwaysSkinFont ? .on : .off
        add(holder, "Shaped Windows (region.txt)", #selector(viewRegion(_:))).state = manager.regionEnabled ? .on : .off
        let items = holder.items
        holder.removeAllItems()
        return items
    }

    @objc func viewToggleScale(_ sender: Any?) { toggleScale() }
    @objc func viewSetScale(_ sender: NSMenuItem) { setScale(sender.tag) }
    @objc func viewAlwaysOnTop(_ sender: Any?) {
        manager.setAlwaysOnTop(!manager.alwaysOnTop)
        publishDebugState()
    }
    @objc func viewToggleEqualizer(_ sender: Any?) { manager.toggleOpen(.equalizer) }
    @objc func viewTogglePlaylist(_ sender: Any?) { manager.toggleOpen(.playlist) }
    @objc func viewToggleShade(_ sender: Any?) { manager.toggleShade(.main) }
    @objc func viewRegroup(_ sender: Any?) { manager.regroup() }
    @objc func viewTimeRemaining(_ sender: Any?) {
        context.updateSettings { $0.timeRemaining.toggle() }
        render()
        publishDebugState()
    }
    @objc func viewSkinFont(_ sender: Any?) { setAlwaysSkinFont(!context.settings.alwaysSkinFont) }
    @objc func viewRegion(_ sender: Any?) { setRegionEnabled(!manager.regionEnabled) }

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

    // MARK: Playlist buttons

    func playlistMenu(_ button: PlaylistMenuButton) -> NSMenu {
        let menu = NSMenu(title: "Playlist")
        menu.autoenablesItems = false
        let s = context.controller.snapshot
        switch button {
        case .add:
            add(menu, "Open Stream URL…", #selector(contextOpenURL(_:)), key: "l")
            add(menu, "Add to Favourites", #selector(contextFavourite(_:)), key: "f").isEnabled = s.stream != nil && !s.isFavourite
        case .remove:
            add(menu, "Never Play This", #selector(contextBan(_:)), key: "\u{8}").isEnabled = s.stream != nil
            let recent = NSMenuItem(title: "Recently Banned", action: nil, keyEquivalent: "")
            recent.submenu = AppMenus.recentlyBannedMenu(context: context, target: self, action: #selector(unbanChosen(_:)))
            menu.addItem(recent)
        case .select:
            add(menu, "Play Selected", #selector(playSelectedRow(_:))).isEnabled =
                !(manager.windows[.playlist]?.skinView.selectedRows.isEmpty ?? true)
            add(menu, "Show Current", #selector(showCurrentRow(_:))).isEnabled = lastState?.currentRow != nil
        case .misc:
            add(menu, "Copy Link", #selector(contextCopyLink(_:)), key: "c", modifiers: [.command, .option]).isEnabled = s.stream != nil
            add(menu, s.isFavourite ? "Remove from Favourites" : "Add to Favourites", #selector(contextFavourite(_:)), key: "f")
                .isEnabled = s.stream != nil
        case .list:
            break
        }
        return menu
    }

    @objc func unbanChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = StreamID(rawValue: raw) else { return }
        context.unban(id)
    }

    @objc func playSelectedRow(_ sender: Any?) {
        guard let row = manager.windows[.playlist]?.skinView.selectedRows.first else { return }
        perform(.playRow(row))
    }

    @objc func showCurrentRow(_ sender: Any?) {
        guard let row = lastState?.currentRow else { return }
        manager.scrollPlaylist(toRow: max(0, row - PlaylistLayout.visibleRows / 2))
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
}
