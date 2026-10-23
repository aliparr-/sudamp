// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Core
import ModernUI
import Playback
import SkinKit

/// The two skin classes (DESIGN §8.4): modern (native glass, the default) and classic (every `.wsz` skin, sudamp
/// Dark included).
nonisolated enum SkinClass: String, CaseIterable, Sendable {
    case modern, classic

    var title: String {
        switch self {
        case .modern: "Modern"
        case .classic: "Classic"
        }
    }
}

/// Shows the player in the chosen skin class and switches between them at run time (DESIGN §8.4). It is the one
/// `PlayerFrontEnd` the app delegate, the menus and automation hold, forwarding to whichever front end is showing:
/// `ModernPlayerUI` or `SkinnedPlayerUI`. It owns the skin library (shared, so decoded skins stay cached across
/// switches) and builds the Skins menu: the modern skin with its appearance and tint, then the classic skins.
///
/// A `.wsz` (drag-and-drop, Open Skin…, an argument, a forwarded launch, Finder) is a classic skin: from the modern
/// skin it is validated first, then shown in the classic windows; a refused one leaves the modern window as it was.
final class PlayerStyleHost: NSObject {
    let context: AppContext
    let library: SkinLibrary
    let isAutomation: Bool
    /// The launch's arguments; `--scale` is cleared once the first classic windows have used it.
    private var arguments: ShellArguments
    private(set) var skinClass: SkinClass
    /// Where a switch already asked for is going (two quick ⇧⌘M presses switch twice).
    private var pendingClass: SkinClass?
    private(set) var active: PlayerUIBase & PlayerFrontEnd
    /// The menu bar, status item and Dock.
    weak var appMenus: AppMenus? {
        didSet { active.appMenus = appMenus }
    }
    private let log = Log.logger("ui")

    /// - Parameter styleOverride: `--style` or the automation script's `style`: this launch only, not remembered.
    init(context: AppContext, arguments: ShellArguments, automation: Bool, styleOverride: SkinClass? = nil) {
        self.context = context
        self.arguments = arguments
        isAutomation = automation
        library = SkinLibrary(bundledDirectory: SkinLibrary.defaultBundledDirectory(), userDirectory: context.paths.skins)
        let saved = SkinClass(rawValue: context.settings.skinClass) ?? .modern
        // A .wsz on the command line shows the classic windows for this launch, once it has passed the loader's checks
        // (the last one that loads wins); refused ones leave the saved class and say why.
        var launchSkin: (SkinEntry, Skin)?
        var rejections: [SkinRejection] = []
        if styleOverride != .modern {
            for path in arguments.skinFiles {
                switch library.importSkin(at: URL(filePath: ShellArguments.absolute(path))) {
                case .success(let loaded): launchSkin = loaded
                case .failure(let rejection): rejections.append(rejection)
                }
            }
        }
        let launchClass = styleOverride ?? (launchSkin != nil ? .classic : saved)
        skinClass = launchClass
        active = Self.make(launchClass, context: context, library: library, arguments: arguments,
                           classicSkin: launchSkin, automation: automation)
        super.init()
        if launchClass == .classic { self.arguments.scale = nil }
        wire(active)
        for rejection in rejections { active.reject(rejection, origin: "launch") }
        if styleOverride == .modern, !arguments.skinFiles.isEmpty {
            log.notice("--style modern: ignored \(arguments.skinFiles.count) skin file(s)")
        }
        log.info("skin class \(launchClass.rawValue, privacy: .public)\(launchClass != saved ? " (this launch)" : "", privacy: .public)")
    }

    private static func make(_ skinClass: SkinClass, context: AppContext, library: SkinLibrary, arguments: ShellArguments,
                             classicSkin: (SkinEntry, Skin)?, automation: Bool) -> PlayerUIBase & PlayerFrontEnd {
        switch skinClass {
        case .classic:
            SkinnedPlayerUI(context: context, library: library, arguments: arguments, initialSkin: classicSkin,
                            automation: automation)
        case .modern:
            ModernPlayerUI(context: context, ignoreOcclusion: arguments.ignoreOcclusion, automation: automation)
        }
    }

    private func wire(_ ui: PlayerUIBase & PlayerFrontEnd) {
        ui.appMenus = appMenus
        ui.skinsMenuProvider = { [weak self] in self?.skinsMenu() ?? NSMenu(title: "Skins") }
        if let modern = ui as? ModernPlayerUI {
            modern.onSwitchToClassic = { [weak self] in self?.switchSoon(to: .classic, origin: "popover") }
            // After the drop has finished: the classic windows replace the one it landed on.
            modern.onSkinFilesDropped = { [weak self] paths in
                DispatchQueue.main.async { self?.loadSkinFiles(paths, origin: "drop") }
            }
        }
    }

    var classic: SkinnedPlayerUI? { active as? SkinnedPlayerUI }
    var modern: ModernPlayerUI? { active as? ModernPlayerUI }

    // MARK: Switching

    /// Switches on the next run-loop turn (a menu item's or popover's action is still unwinding now).
    func switchSoon(to newClass: SkinClass, origin: String, classicSkin: (SkinEntry, Skin)? = nil) {
        pendingClass = newClass
        DispatchQueue.main.async { [weak self] in
            self?.pendingClass = nil
            self?.setSkinClass(newClass, origin: origin, classicSkin: classicSkin)
        }
    }

    /// Shows the other skin class: the old windows fade out as the new ones come in, the choice is remembered.
    /// - Parameter classicSkin: a skin already loaded for the classic windows (else they show the saved one).
    func setSkinClass(_ newClass: SkinClass, origin: String, classicSkin: (SkinEntry, Skin)? = nil) {
        guard newClass != skinClass, !context.isShutDown else { return }
        let old = active
        let oldWindow = old.mainWindow
        let wasVisible = oldWindow?.isVisible ?? false
        retire(old, animated: wasVisible && !isAutomation)
        skinClass = newClass
        let ui = Self.make(newClass, context: context, library: library, arguments: arguments, classicSkin: classicSkin,
                           automation: isAutomation)
        if newClass == .classic { arguments.scale = nil }
        wire(ui)
        // The automation report spans the switch.
        ui.menuSelections = old.menuSelections
        ui.menuDumps = old.menuDumps
        ui.openedMenus = old.openedMenus
        if old.menuAutoOpened { ui.markMenuAutoOpened() }
        active = ui
        context.updateSettings { $0.skinClass = newClass.rawValue }
        context.controller.metrics?.record("skinClass", ["class": newClass.rawValue, "origin": origin])
        log.info("skin class \(newClass.rawValue, privacy: .public) from \(origin, privacy: .public)")
        // Outside automation the new skin always shows (the old window may have been minimised or the app hidden).
        if isAutomation {
            if wasVisible { ui.show(activate: false) }
        } else {
            ui.show(activate: true)
        }
        ui.render()
        appMenus?.frontEndChanged()
        ui.publishDebugState()
    }

    /// Closes a front end that is being replaced, fading its windows out first.
    private func retire(_ ui: PlayerUIBase & PlayerFrontEnd, animated: Bool) {
        ui.cancelMenuTracking()
        let windows: [NSWindow]
        if let classic = ui as? SkinnedPlayerUI {
            windows = classic.manager.windows.values.filter(\.isVisible)
        } else if let modern = ui as? ModernPlayerUI {
            windows = modern.player.window.isVisible ? [modern.player.window] : []
        } else {
            windows = []
        }
        let close: @MainActor () -> Void = {
            if let classic = ui as? SkinnedPlayerUI { classic.close() }
            if let modern = ui as? ModernPlayerUI { modern.close() }
            for window in windows { window.alphaValue = 1 }
        }
        guard animated, !windows.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return close() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            for window in windows { window.animator().alphaValue = 0 }
        }, completionHandler: { MainActor.assumeIsolated { close() } })
    }

    /// Quit path.
    func close() {
        if let classic { classic.close() }
        if let modern { modern.close() }
    }

    // MARK: Classic skins

    /// A classic skin by id (Skins menu, automation): shown in the classic windows, switching to them if needed.
    @discardableResult
    func selectClassicSkin(id: String, origin: String) -> Bool {
        if let classic { return classic.selectSkin(id: id, origin: origin) }
        guard let entry = library.entry(id: id) else { return false }
        switch library.load(entry) {
        case .success(let skin):
            showClassic(entry, skin: skin, origin: origin)
            return true
        case .failure(let rejection):
            active.reject(rejection, origin: origin)
            return false
        }
    }

    /// Shows a loaded classic skin in the classic windows, remembering both.
    private func showClassic(_ entry: SkinEntry, skin: Skin, origin: String) {
        context.updateSettings { $0.skin = entry.id == SkinLibrary.builtInID ? nil : entry.id }
        context.controller.metrics?.record("skin", ["id": entry.id, "origin": origin])
        setSkinClass(.classic, origin: origin, classicSkin: (entry, skin))
    }

    func openSkinPanel() {
        guard !isAutomation else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Skin"
        panel.message = "Choose a classic skin (.wsz)."
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.delegate = active
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { loadSkinFiles([url.path], origin: "openPanel") }
    }

    // MARK: Menus

    /// The Skins menu (menu bar, context menus): the modern skin with its appearance and tint, then the classic skins,
    /// then Open Skin…, the skins folder and the museum's site.
    func skinsMenu() -> NSMenu {
        let menu = NSMenu(title: "Skins")
        menu.autoenablesItems = false
        let toggle = add(menu, skinClass == .modern ? "Use Classic Skins" : "Use Modern Skin", #selector(toggleSkinClass(_:)),
                         key: "m", modifiers: [.command, .shift])
        toggle.toolTip = "Switch between the modern glass skin and the classic .wsz skins"
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Modern"))
        let modernAppearance = ModernPlayerUI.appearance(context.settings)
        let modernTint = ModernPlayerUI.tint(context.settings)
        let modernItem = add(menu, SkinLibrary.modernName, #selector(modernChosen(_:)))
        modernItem.state = skinClass == .modern ? .on : .off
        modernItem.subtitle = "Liquid Glass · \(modernAppearance.title) · \(modernTint.title)"
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = Self.appearanceMenu(current: modernAppearance, target: self, action: #selector(appearanceChosen(_:)))
        menu.addItem(appearance)
        let tint = NSMenuItem(title: "Tint", action: nil, keyEquivalent: "")
        tint.submenu = Self.tintMenu(current: modernTint, target: self, action: #selector(tintChosen(_:)))
        menu.addItem(tint)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Classic"))
        let currentClassic = classic?.skinEntry.id ?? context.settings.skin ?? SkinLibrary.builtInID
        var origin: SkinEntry.Origin?
        var museum: NSMenuItem?
        for entry in library.entries() {
            if let origin, origin != entry.origin { menu.addItem(.separator()) }
            origin = entry.origin
            var parent = menu
            if entry.origin == .museum {
                // A hundred skins get a submenu, so the user's skins and Open Skin… stay on screen.
                if museum == nil {
                    let holder = NSMenuItem(title: Self.museumMenuTitle, action: nil, keyEquivalent: "")
                    let submenu = NSMenu(title: Self.museumMenuTitle)
                    submenu.autoenablesItems = false
                    holder.submenu = submenu
                    menu.addItem(holder)
                    museum = holder
                }
                parent = museum?.submenu ?? menu
            }
            let item = add(parent, entry.name, #selector(classicChosen(_:)))
            item.representedObject = entry.id
            item.state = skinClass == .classic && entry.id == currentClassic ? .on : .off
            if item.state == .on, parent !== menu { museum?.state = .on }
            if let credit = entry.credit {
                item.toolTip = credit
                // Under every museum skin a subtitle would double the submenu's height; the tooltip is enough.
                if entry.origin != .museum { item.subtitle = credit }
            }
        }
        menu.addItem(.separator())
        add(menu, "Open Skin…", #selector(openSkin(_:)), key: "o", modifiers: [.command, .shift])
        add(menu, "Show Skins Folder", #selector(showSkinsFolder(_:)))
        add(menu, "Get More Skins…", #selector(getMoreSkins(_:)))
        return menu
    }

    static let museumMenuTitle = "Skin Museum"

    /// Automatic, Light, Dark.
    static func appearanceMenu(current: ModernAppearance, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Appearance")
        menu.autoenablesItems = false
        for mode in ModernAppearance.allCases {
            let item = menu.addItem(withTitle: mode.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = mode.rawValue
            item.state = mode == current ? .on : .off
            let symbol = switch mode {
            case .auto: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return menu
    }

    /// Every tint, each with a swatch of its colour.
    static func tintMenu(current: ModernTint, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Tint")
        menu.autoenablesItems = false
        for tint in ModernTint.allCases {
            let item = menu.addItem(withTitle: tint.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = tint.rawValue
            item.state = tint == current ? .on : .off
            item.image = swatch(tint)
        }
        return menu
    }

    /// A 12-point disc of the tint (2x bitmap), for the app's current appearance: menus are rebuilt each time they open.
    static func swatch(_ tint: ModernTint) -> NSImage {
        let dark = NSApp?.effectiveAppearance.isDark ?? false
        let c = dark ? tint.accent.dark : tint.accent.light
        let deep = tint.deep(dark: dark)
        let size = 24
        let image = NSImage(size: NSSize(width: 12, height: 12))
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let rect = CGRect(x: 1, y: 1, width: size - 2, height: size - 2)
        ctx.addEllipse(in: rect)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c.adjusted(brightness: 1.1).cgColor,
                                  deep.cgColor] as CFArray, locations: [0, 1])
        if let gradient {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 6, y: CGFloat(size)), end: CGPoint(x: 18, y: 0), options: [])
        }
        ctx.resetClip()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.15))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: rect)
        if let cg = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = image.size
            image.addRepresentation(rep)
        }
        return image
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                     modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = self
        return item
    }

    @objc func toggleSkinClass(_ sender: Any?) {
        let current = pendingClass ?? skinClass
        active.recordSelection(menu: "skins", item: current == .modern ? "Use Classic Skins" : "Use Modern Skin")
        switchSoon(to: current == .modern ? .classic : .modern, origin: "menu")
    }

    @objc func modernChosen(_ sender: NSMenuItem) {
        active.recordSelection(menu: "skins", item: sender.title)
        switchSoon(to: .modern, origin: "menu")
    }

    @objc func classicChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        active.recordSelection(menu: "skins", item: sender.title)
        if let classic {
            _ = classic.selectSkin(id: id, origin: "menu")
        } else {
            // After the menu has closed: the classic windows replace the one the menu came from.
            DispatchQueue.main.async { [weak self] in self?.selectClassicSkin(id: id, origin: "menu") }
        }
    }

    /// Choosing an appearance or tint shows the modern skin in it.
    @objc func appearanceChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let appearance = ModernAppearance(rawValue: raw) else { return }
        active.recordSelection(menu: "skins", item: "Appearance/\(sender.title)")
        context.updateSettings { $0.modernAppearance = appearance.rawValue }
        if let modern { modern.setAppearance(appearance) } else { switchSoon(to: .modern, origin: "menu") }
    }

    @objc func tintChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tint = ModernTint(rawValue: raw) else { return }
        active.recordSelection(menu: "skins", item: "Tint/\(sender.title)")
        context.updateSettings { $0.modernTint = tint.rawValue }
        if let modern { modern.setTint(tint) } else { switchSoon(to: .modern, origin: "menu") }
    }

    @objc func openSkin(_ sender: Any?) { openSkinPanel() }

    @objc func showSkinsFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: context.paths.skins, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([context.paths.skins])
    }

    /// "Get more skins…" opens skins.webamp.org (DESIGN §8.3).
    @objc func getMoreSkins(_ sender: Any?) {
        if let url = URL(string: "https://skins.webamp.org/") { NSWorkspace.shared.open(url) }
    }

    /// The View menu: the showing front end's.
    func viewItems() -> [NSMenuItem] { active.viewItems() }
    func render() { active.render() }
    var aboutSkin: SkinEntry? { active.aboutSkin }
}

// MARK: - PlayerFrontEnd

extension PlayerStyleHost: PlayerFrontEnd {
    var modeName: String { active.modeName }
    var mainWindow: NSWindow? { active.mainWindow }
    func show(activate: Bool) { active.show(activate: activate) }
    func openGenreMenuSoon() { active.openGenreMenuSoon() }
    func pickGenre() { active.pickGenre() }
    func cancelMenuTracking() { active.cancelMenuTracking() }
    func syncVolume() { active.syncVolume() }
    func promptForStreamURL() { active.promptForStreamURL() }
    func publishDebugState() { active.publishDebugState() }

    /// Classic skins: loaded by the classic windows; from the modern skin, the last one that loads is shown in them.
    func loadSkinFiles(_ paths: [String], origin: String) {
        if let classic { return classic.loadSkinFiles(paths, origin: origin) }
        var chosen: (SkinEntry, Skin)?
        for path in paths {
            switch library.importSkin(at: URL(filePath: ShellArguments.absolute(path))) {
            case .success(let loaded): chosen = loaded
            case .failure(let rejection): active.reject(rejection, origin: origin)
            }
        }
        if let (entry, skin) = chosen { showClassic(entry, skin: skin, origin: origin) }
    }

    func automationSelect(_ choice: GenreMenuChoice) async -> (Bool, String?) { await active.automationSelect(choice) }
    func automationPress(_ control: AutomationScript.Control) { active.automationPress(control) }
    func automationSetVolume(_ v: Double) { active.automationSetVolume(v) }
    func snapshot(to url: URL) throws { try active.snapshot(to: url) }
    var automationReport: [String: Any] { active.automationReport }
    func automationWillStart(firstLaunch: Bool) { active.automationWillStart(firstLaunch: firstLaunch) }
    func automationDidFinish() { active.automationDidFinish() }

    /// `loadSkin` may change the skin class; everything else is the showing front end's.
    func perform(_ step: ShellAutomationScript.SkinStep) async -> (Bool, String?) {
        guard case let .loadSkin(spec, expectRejection) = step, classic == nil else { return await active.perform(step) }
        let before = context.controller.snapshot.lastError
        if library.entry(id: spec) != nil {
            selectClassicSkin(id: spec, origin: "automation")
        } else {
            loadSkinFiles([spec], origin: "automation")
        }
        let after = context.controller.snapshot.lastError
        let rejected = after != before && after?.kind == "skinRejected"
        let note = rejected ? "rejected: \(after?.message ?? "")" : "skin \(classic?.skinEntry.id ?? "-") (classic)"
        return (rejected == expectRejection, note)
    }
}
