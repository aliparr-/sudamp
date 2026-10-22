// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Audio
import Catalog
import Core
import Playback
import SkinKit
import SkinUI

/// The default front end (PLAN M5, DESIGN §3, §8): Main (+ shade), Equalizer and Playlist SkinWindows through
/// SkinUI's WindowManager, drawn from PlaybackController snapshots (`SkinDisplay`), with every SkinControlEvent
/// turned into an action (`SkinActions`). The genre menu opens from the marquee, the options button and right-click
/// `Genre ▸`, always the same `GenreMenuBuilder` menu anchored under the marquee; the first launch opens it by itself.
/// Skins come from `SkinLibrary` (built in, bundled, `<profile>/Skins`), by drag-and-drop, Open Skin…, a `.wsz`
/// argument or a forwarded launch; a refused archive shows a sheet and keeps the current skin.
///
/// The visualiser is AudioEngine's `VisualiserAnalyser` over the render bridge's ring, pulled by SkinUI's display link
/// at 30 Hz only while Main is visible and playing (paused when occluded).
final class SkinnedPlayerUI: NSObject {
    let context: AppContext
    let manager: WindowManager
    let library: SkinLibrary
    let isAutomation: Bool
    /// The menu bar, status item and Dock (menus dump).
    weak var appMenus: AppMenus?
    private(set) var skinEntry: SkinEntry
    private var analyser: VisualiserAnalyser?
    private(set) var lastState: SkinPlayerState?
    private var lastCurrentID: StreamID?
    private var lastDebug: (skin: AppSkinDebugInfo?, ui: AppUIDebugInfo?)?

    // Menus (SkinnedPlayerUI+Menus.swift)
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
    private var sheetOpen = false

    init(context: AppContext, arguments: ShellArguments, automation: Bool) {
        self.context = context
        isAutomation = automation
        library = SkinLibrary(bundledDirectory: SkinLibrary.defaultBundledDirectory(), userDirectory: context.paths.skins)
        let settings = context.settings
        var entry = SkinLibrary.builtIn
        var skin = SudampDark.skin
        var rejected: SkinRejection?
        if let path = arguments.skinFiles.last {
            switch library.importSkin(at: URL(filePath: ShellArguments.absolute(path))) {
            case .success(let (e, s)): (entry, skin) = (e, s)
            case .failure(let r): rejected = r
            }
        } else if let saved = settings.skin, let e = library.entry(id: saved), case .success(let s) = library.load(e) {
            (entry, skin) = (e, s)
        }
        skinEntry = entry
        var configuration = WindowManager.Configuration()
        configuration.scale = arguments.scale
        configuration.layoutURL = context.paths.appSupport.appending(path: "layout.json")
        configuration.regionEnabled = settings.regionEnabled && !arguments.noRegion
        manager = WindowManager(skin: skin, configuration: configuration)
        super.init()
        manager.pausesWhenOccluded = !arguments.ignoreOcclusion
        manager.onEvent = { [weak self] event, role in self?.handle(event, from: role) }
        manager.onFilesDropped = { [weak self] urls, _ in
            self?.loadSkinFiles(urls.map(\.path), origin: "drop")
            return true
        }
        manager.onLayoutChange = { [weak self] in self?.publishDebugState() }
        manager.visualizerProvider = { [weak self] in self?.visualizerFrame() }
        let undo = context.undoManager
        for window in manager.windows.values {
            window.undoManagerProvider = { undo }
            window.delegate = self
        }
        context.observeSnapshots { [weak self] s in self?.render(s) }
        if let rejected { reject(rejected, origin: "launch") }
        log.info("skinned UI: skin \(entry.id, privacy: .public), scale \(self.manager.scale)")
        publishDebugState()
    }

    let log = Log.logger("ui")

    var mainWindow: NSWindow? { manager.windows[.main] }

    // MARK: Showing

    func show(activate: Bool) {
        if let main = manager.windows[.main], main.isMiniaturized { main.deminiaturize(nil) }
        manager.show()
        if activate { NSApp.activate() }
        publishDebugState()
    }

    /// Orders the windows in without making the app active (automation never takes focus).
    func showWithoutActivating() {
        for role in [SkinWindowRole.playlist, .equalizer, .main] where manager.isOpen(role) {
            manager.windows[role]?.orderFront(nil)
        }
        publishDebugState()
    }

    // MARK: Rendering

    /// Snapshot (+ settings, library) → what the skin draws.
    func render(_ s: PlayerSnapshot? = nil) {
        let snapshot = s ?? context.controller.snapshot
        let controller = context.controller
        let playlist = SkinDisplay.playlist(genre: snapshot.genre, favouritesMode: snapshot.favouritesMode,
                                            catalog: controller.catalog, favourites: controller.favouriteStreams,
                                            banned: controller.library.bannedSet)
        let remembered = snapshot.genre == nil && snapshot.phase == .idle
            ? context.rememberedGenre.flatMap { controller.catalog.genre($0)?.name } : nil
        let state = SkinDisplay.playerState(snapshot, playlist: playlist, equalizer: controller.equalizer,
                                            prefs: SkinPrefs(context.settings), rememberedGenre: remembered)
        guard state != lastState else { return }
        let previousEQ = lastState?.equalizer
        lastState = state
        manager.playerState = state
        if snapshot.stream?.id != lastCurrentID {
            lastCurrentID = snapshot.stream?.id
            if let row = state.currentRow, let view = manager.windows[.playlist]?.skinView {
                let first = view.firstVisibleRow
                if row < first || row >= first + PlaylistLayout.visibleRows {
                    manager.scrollPlaylist(toRow: max(0, row - PlaylistLayout.visibleRows / 2))
                }
            }
        }
        if previousEQ != state.equalizer { publishDebugState() }
    }

    /// 19 bars, peaks and 76 scope samples from the analyser (allocated on first use; nil = silence).
    private func visualizerFrame() -> VisualizerSnapshot? {
        if analyser == nil, let bridge = context.controller.renderBridge { analyser = VisualiserAnalyser(bridge: bridge) }
        guard let analyser else { return nil }
        let frame = analyser.analyse()
        return VisualizerSnapshot(bars: frame.bars, scope: frame.scope, peaks: frame.peaks)
    }

    // MARK: Events

    func handle(_ event: SkinControlEvent, from role: SkinWindowRole) {
        let s = context.controller.snapshot
        let action = SkinActions.action(for: event, snapshot: s,
                                        canPlayWithoutPick: s.genre != nil || context.rememberedGenre != nil)
        if case .none = action {
            if case .clutter = event { publishDebugState() }
            return
        }
        log.debug("event \(event.description, privacy: .public) → \(String(describing: action), privacy: .public)")
        perform(action)
    }

    func perform(_ action: SkinAction) {
        let controller = context.controller
        switch action {
        case .play: context.perform(.play, origin: "skin")
        case .resume: context.perform(.play, origin: "skin")
        case .pause: context.perform(.pause, origin: "skin")
        case .stop: context.perform(.stop, origin: "skin")
        case .next: context.perform(.next, origin: "skin")
        case .previous: context.perform(.previous, origin: "skin")
        case .retry: context.retry()
        case .seek(let fraction): controller.seek(toFraction: fraction)
        case .volume(let v): context.setVolume(v)
        case .balance(let b): context.setBalance(b)
        case let .eqBand(index, db):
            var eq = controller.equalizer
            eq.bands[index] = Float(db)
            context.setEqualizer(eq, preset: nil)
        case .preamp(let db):
            var eq = controller.equalizer
            eq.preamp = Float(db)
            context.setEqualizer(eq, preset: nil)
        case .eqToggle:
            var eq = controller.equalizer
            eq.enabled.toggle()
            context.setEqualizer(eq, preset: context.settings.eqPreset)
        case .eqAuto:
            context.updateSettings { $0.eqAuto.toggle() }
        case .eqSetAll(let db):
            var eq = controller.equalizer
            eq.bands = [Float](repeating: Float(db), count: EQSettings.bandCount)
            context.setEqualizer(eq, preset: nil)
        case .genreMenu(let anchor): openGenreMenu(anchor)
        case .contextMenu(let point): popUp(contextMenu(), at: point, kind: "context", anchor: nil)
        case .presetsMenu(let point): popUp(presetsMenu(), at: point, kind: "presets", anchor: nil)
        case .visualizerMenu(let point): popUp(visualizerMenu(), at: point, kind: "visualizer", anchor: nil)
        case .streamInfoMenu(let point): popUp(streamInfoMenu(), at: point, kind: "info", anchor: nil)
        case let .playlistMenu(button, point):
            if button == .list {
                openGenreMenu(.marquee, at: point)
            } else {
                popUp(playlistMenu(button), at: point, kind: "playlist.\(button.rawValue)", anchor: nil)
            }
        case .toggleShuffle: context.toggleShuffle()
        case .toggleRepeat: context.toggleRepeat()
        case .openStreamURL: promptForStreamURL()
        case .playRow(let index):
            guard let rows = lastPlaylistIDs(), index >= 0, index < rows.count else { return }
            controller.play(stream: rows[index])
        case .toggleTimeDisplay:
            context.updateSettings { $0.timeRemaining.toggle() }
        case .cycleVisualizer:
            let next: VisualizerFrame.Mode = switch SkinPrefs(context.settings).visualizer {
            case .spectrum: .oscilloscope
            case .oscilloscope: .off
            case .off: .spectrum
            }
            setVisualizer(next)
        case .about: AppMenus.showAbout(skin: skinEntry)
        case .quit: context.onQuit?("main window closed")
        case .none: return
        }
        render()
    }

    func setVisualizer(_ mode: VisualizerFrame.Mode) {
        context.updateSettings { $0.visualizer = SkinPrefs.name(mode) }
        render()
        publishDebugState()
    }

    /// The Playlist's stream IDs in row order (what `playRow` and double-clicks index).
    func lastPlaylistIDs() -> [StreamID]? {
        let controller = context.controller
        let s = controller.snapshot
        return SkinDisplay.playlist(genre: s.genre, favouritesMode: s.favouritesMode, catalog: controller.catalog,
                                    favourites: controller.favouriteStreams, banned: controller.library.bannedSet).map(\.id)
    }

    func promptForStreamURL() {
        StreamURLPrompt.run(context: context, window: manager.windows[.main], automation: isAutomation)
    }

    func syncVolume() { render() }

    // MARK: Skins

    /// Loads skin files (drop, Open Skin…, argument, forwarded launch); the last one that loads wins.
    func loadSkinFiles(_ paths: [String], origin: String) {
        for path in paths {
            let url = URL(filePath: ShellArguments.absolute(path))
            switch library.importSkin(at: url) {
            case .success(let (entry, skin)): apply(entry, skin: skin, origin: origin)
            case .failure(let rejection): reject(rejection, origin: origin)
            }
        }
    }

    /// A library skin by id (Skins menu, automation).
    func selectSkin(id: String, origin: String) -> Bool {
        guard let entry = library.entry(id: id) else { return false }
        switch library.load(entry) {
        case .success(let skin):
            apply(entry, skin: skin, origin: origin)
            return true
        case .failure(let rejection):
            reject(rejection, origin: origin)
            return false
        }
    }

    func apply(_ entry: SkinEntry, skin: Skin, origin: String) {
        skinEntry = entry
        manager.setSkin(skin)
        context.updateSettings { $0.skin = entry.id == SkinLibrary.builtInID ? nil : entry.id }
        log.info("skin \(entry.id, privacy: .public) from \(origin, privacy: .public)")
        context.controller.metrics?.record("skin", ["id": entry.id, "origin": origin,
                                                    "fallbackSheets": skin.report.fallbackSheets.count])
        lastState = nil
        render()
        publishDebugState()
    }

    /// A refused archive (DESIGN §8.2): the current skin stays; `.lastError.kind == "skinRejected"`; a window-modal
    /// sheet says why (dismissed by itself under `--automation`).
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

    /// A window-modal sheet on Main (shown even while Main is off screen under automation, then dismissed).
    func showSheet(_ alert: NSAlert, name: String) {
        lastSheet = name
        guard let main = manager.windows[.main] else { return }
        if main.attachedSheet != nil { main.endSheet(main.attachedSheet!) }
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

    func openSkinPanel() {
        guard !isAutomation else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Skin"
        panel.message = "Choose a classic skin (.wsz)."
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.delegate = self
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { loadSkinFiles([url.path], origin: "openPanel") }
    }

    // MARK: Window management (View menu)

    func setScale(_ scale: Int) {
        manager.setScale(scale)
        publishDebugState()
    }

    func toggleScale() {
        manager.toggleScale()
        publishDebugState()
    }

    func setRegionEnabled(_ on: Bool) {
        manager.setRegionEnabled(on)
        context.updateSettings { $0.regionEnabled = on }
        publishDebugState()
    }

    func setAlwaysSkinFont(_ on: Bool) {
        context.updateSettings { $0.alwaysSkinFont = on }
        render()
    }

    // MARK: Debug state

    func publishDebugState() {
        let skin = SkinLibrary.debugInfo(skinEntry, skin: manager.skin)
        var windows: [String: AppUIDebugInfo.Window] = [:]
        for (role, window) in manager.windows {
            let f = window.frame
            windows[role.rawValue] = .init(open: manager.isOpen(role), shaded: manager.isShaded(role),
                                           visible: window.isVisible, frame: [f.minX, f.minY, f.width, f.height])
        }
        let eq = context.controller.equalizer
        let settings = context.settings
        let ui = AppUIDebugInfo(
            mode: "skinned", scale: manager.scale, windows: windows, alwaysOnTop: manager.alwaysOnTop,
            regionEnabled: manager.regionEnabled, menuAutoOpened: menuAutoOpened, openMenu: openMenuKind,
            equalizer: .init(enabled: eq.enabled, auto: settings.eqAuto, preamp: Double(eq.preamp),
                             bands: eq.bands.map(Double.init), preset: settings.eqPreset),
            timeDisplay: settings.timeRemaining ? "remaining" : "elapsed", visualizerMode: settings.visualizer,
            lastSheet: lastSheet, sheetOpen: sheetOpen)
        context.controller.setShellState(skin: skin, ui: ui)
    }

    func markMenuAutoOpened() {
        menuAutoOpened = true
        publishDebugState()
    }

    /// Quit path: stop observers and display links, save the layout.
    func close() {
        cancelMenuTracking()
        manager.saveLayout()
        manager.close()
    }
}

extension SkinnedPlayerUI: NSWindowDelegate {
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { context.undoManager }
}

extension SkinnedPlayerUI: NSOpenSavePanelDelegate {
    /// Open Skin… lists folders and skin archives only.
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.hasDirectoryPath || SkinView.isSkinFile(url) || ["eqf", "q1"].contains(url.pathExtension.lowercased())
    }
}
