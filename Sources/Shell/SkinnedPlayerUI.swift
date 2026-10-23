// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Audio
import Catalog
import Core
import Playback
import SkinKit
import SkinUI

/// The classic skins' front end (PLAN M5, DESIGN §3, §8, §8.4): Main (+ shade), Equalizer and Playlist SkinWindows through
/// SkinUI's WindowManager, drawn from PlaybackController snapshots (`SkinDisplay`), with every SkinControlEvent
/// turned into an action (`SkinActions`). The genre menu opens from the marquee, the options button and right-click
/// `Genre ▸`, always the same `GenreMenuBuilder` menu anchored under the marquee; the first launch opens it by itself.
/// Skins come from `SkinLibrary` (built in, bundled, the museum's, `<profile>/Skins`), by drag-and-drop, Open Skin…,
/// a `.wsz` argument or a forwarded launch; a refused archive shows a sheet and keeps the current skin. Menus, sheets
/// and the menu automation are `PlayerUIBase`'s; `PlayerStyleHost` switches between this and the modern skin.
///
/// The visualiser is AudioEngine's `VisualiserAnalyser` over the render bridge's ring, pulled by SkinUI's display link
/// at 30 Hz only while Main is visible and playing (paused when occluded).
final class SkinnedPlayerUI: PlayerUIBase {
    let manager: WindowManager
    let library: SkinLibrary
    private(set) var skinEntry: SkinEntry
    private var analyser: VisualiserAnalyser?
    private(set) var lastState: SkinPlayerState?
    private var lastCurrentID: StreamID?
    private var snapshotObserver: Int?

    /// - Parameter initialSkin: a skin already loaded and validated (a `.wsz` argument, a file opened or dropped on the
    ///   modern skin); nil shows the saved one.
    init(context: AppContext, library: SkinLibrary, arguments: ShellArguments, initialSkin: (SkinEntry, Skin)?,
         automation: Bool) {
        self.library = library
        let settings = context.settings
        var entry = SkinLibrary.builtIn
        var skin = SudampDark.skin
        if let initialSkin {
            (entry, skin) = initialSkin
        } else if let saved = settings.skin, let e = library.entry(id: saved), case .success(let s) = library.load(e) {
            (entry, skin) = (e, s)
        }
        skinEntry = entry
        var configuration = WindowManager.Configuration()
        configuration.scale = arguments.scale
        configuration.layoutURL = context.paths.appSupport.appending(path: "layout.json")
        configuration.regionEnabled = settings.regionEnabled && !arguments.noRegion
        manager = WindowManager(skin: skin, configuration: configuration)
        super.init(context: context, automation: automation)
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
        snapshotObserver = context.observeSnapshots { [weak self] s in self?.render(s) }
        log.info("skinned UI: skin \(entry.id, privacy: .public), scale \(SkinScale.label(self.manager.scale), privacy: .public)")
        publishDebugState()
    }


    var mainWindow: NSWindow? { manager.windows[.main] }
    override var sheetWindow: NSWindow? { manager.windows[.main] }
    override func genreMenuAnchorPoint() -> CGPoint { manager.marqueeMenuAnchor() }
    override var aboutSkin: SkinEntry? { skinEntry }

    override func presetsMenuAnchorPoint() -> CGPoint {
        let presets = manager.windows[.equalizer]?.skinView.screenRect(forSkinRect: EQLayout.presets) ?? .zero
        return CGPoint(x: presets.minX, y: presets.minY)
    }

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
    override func render(_ s: PlayerSnapshot? = nil) {
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
            cycleVisualizer()
        case .about: AppMenus.showAbout(skin: skinEntry)
        case .quit: context.onQuit?("main window closed")
        case .none: return
        }
        render()
    }

    /// The Playlist's stream IDs in row order (what `playRow` and double-clicks index).
    func lastPlaylistIDs() -> [StreamID]? {
        let controller = context.controller
        let s = controller.snapshot
        return SkinDisplay.playlist(genre: s.genre, favouritesMode: s.favouritesMode, catalog: controller.catalog,
                                    favourites: controller.favouriteStreams, banned: controller.library.bannedSet).map(\.id)
    }

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

    // MARK: Window management (View menu)

    func setScale(_ scale: Double) {
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

    override func publishDebugState() {
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
            lastSheet: lastSheet, sheetOpen: sheetOpen, skinClass: "classic")
        context.controller.setShellState(skin: skin, ui: ui)
    }

    /// Quit path or a switch to the modern skin: stop observers and display links, save the layout, hide.
    func close() {
        cancelMenuTracking()
        if let snapshotObserver { context.removeObserver(snapshotObserver) }
        snapshotObserver = nil
        if let main = manager.windows[.main], let sheet = main.attachedSheet { main.endSheet(sheet) }
        manager.saveLayout()
        manager.close()
    }
}

extension SkinnedPlayerUI: NSWindowDelegate {
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { context.undoManager }
}


