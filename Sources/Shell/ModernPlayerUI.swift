// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Audio
import Catalog
import Core
import ModernUI
import Playback
import SkinKit

/// The modern skin's front end (DESIGN §8.4): ModernUI's glass window drawn from PlaybackController snapshots
/// (`ModernDisplay`), with every ModernEvent turned into an action. The genre menu opens under the genre button (and
/// from the context menu, the menu bar, the status item and the Dock: the same menu everywhere, `PlayerUIBase`); the
/// first launch opens it by itself. Appearance and tint come from settings.json and change live from the appearance
/// popover or the View menu.
///
/// The visualiser is the same `VisualiserAnalyser` as the classic skins', pulled by ModernUI's display link at 30 Hz
/// only while the artwork animates and the window can be seen.
final class ModernPlayerUI: PlayerUIBase {
    let player: ModernPlayer
    private var analyser: VisualiserAnalyser?
    private(set) var lastState: ModernPlayerState?
    private var snapshotObserver: Int?
    /// A switch to the classic skins (the appearance popover's button): the host acts on it.
    var onSwitchToClassic: (() -> Void)?
    /// Classic skin files dropped on the window: the host validates them and switches.
    var onSkinFilesDropped: (([String]) -> Void)?

    static let skinEntry = SkinEntry(id: SkinLibrary.modernID, name: SkinLibrary.modernName, origin: .builtIn, url: nil,
                                     credit: nil)

    init(context: AppContext, ignoreOcclusion: Bool, automation: Bool) {
        var configuration = ModernPlayer.Configuration()
        configuration.layoutURL = context.paths.appSupport.appending(path: "modern-layout.json")
        configuration.appearance = Self.appearance(context.settings)
        configuration.tint = Self.tint(context.settings)
        player = ModernPlayer(configuration: configuration)
        super.init(context: context, automation: automation)
        player.pausesWhenOccluded = !ignoreOcclusion
        player.onEvent = { [weak self] event in self?.handle(event) }
        player.visualizerProvider = { [weak self] in self?.visualizerFrame() }
        player.window.delegate = self
        player.onNotice = { [weak self] message in self?.log.notice("\(message, privacy: .public)") }
        player.onVisualizerChange = { [weak self] running in
            guard let self else { return }
            self.log.notice("visualizer \(running ? "running" : "paused", privacy: .public): \(self.visualizerDetail, privacy: .public)")
            self.publishDebugState()
        }
        player.onFilesDropped = { [weak self] urls in
            guard let self, let handler = self.onSkinFilesDropped else { return false }
            handler(urls.map(\.path))
            return true
        }
        snapshotObserver = context.observeSnapshots { [weak self] s in self?.render(s) }
        log.info("modern UI: \(configuration.appearance.rawValue, privacy: .public), \(configuration.tint.rawValue, privacy: .public)")
        publishDebugState()
    }

    static func appearance(_ settings: AppSettings) -> ModernAppearance {
        ModernAppearance(rawValue: settings.modernAppearance) ?? .default
    }

    static func tint(_ settings: AppSettings) -> ModernTint {
        ModernTint(rawValue: settings.modernTint) ?? .default
    }

    var mainWindow: NSWindow? { player.window }
    override var sheetWindow: NSWindow? { player.window }
    override func genreMenuAnchorPoint() -> CGPoint { player.genreMenuAnchor() }
    override func presetsMenuAnchorPoint() -> CGPoint { player.presetsMenuAnchor() }
    override var aboutSkin: SkinEntry? { Self.skinEntry }

    // MARK: Showing

    func show(activate: Bool) {
        player.show(activate: activate)
        if activate { NSApp.activate() }
        publishDebugState()
    }

    // MARK: Rendering

    override func render(_ s: PlayerSnapshot? = nil) {
        let snapshot = s ?? context.controller.snapshot
        let controller = context.controller
        let playlist = SkinDisplay.playlist(genre: snapshot.genre, favouritesMode: snapshot.favouritesMode,
                                            catalog: controller.catalog, favourites: controller.favouriteStreams,
                                            banned: controller.library.bannedSet)
        let remembered = snapshot.genre == nil && snapshot.phase == .idle
            ? context.rememberedGenre.flatMap { controller.catalog.genre($0)?.name } : nil
        let settings = context.settings
        let prefs = ModernDisplay.Prefs(timeRemaining: settings.timeRemaining, visualizer: settings.modernVisualizer,
                                        eqPreset: settings.eqPreset, muted: context.muted,
                                        visualizerInterval: settings.visualizerInterval, artworkColors: settings.artworkColors,
                                        visualizerEffect: settings.visualizerEffect)
        let state = ModernDisplay.state(snapshot, playlist: playlist, equalizer: controller.equalizer, prefs: prefs,
                                        rememberedGenre: remembered)
        guard state != lastState else { return }
        let eqChanged = state.equalizer != lastState?.equalizer
        lastState = state
        player.state = state
        if eqChanged { publishDebugState() }
    }

    /// 19 bars with their peaks and 76 scope samples from the analyser (allocated on first use; nil = silence).
    private func visualizerFrame() -> ModernVisualizerFrame? {
        if analyser == nil, let bridge = context.controller.renderBridge { analyser = VisualiserAnalyser(bridge: bridge) }
        guard let analyser else { return nil }
        let frame = analyser.analyse()
        return ModernVisualizerFrame(bars: frame.bars, peaks: frame.peaks, scope: frame.scope)
    }

    // MARK: Events

    func handle(_ event: ModernEvent) {
        let controller = context.controller
        log.debug("modern event \(event.description, privacy: .public)")
        switch event {
        case .playPause:
            let s = controller.snapshot
            if s.phase == .idle, s.genre == nil, !s.favouritesMode, context.rememberedGenre == nil {
                openGenreMenu(.marquee)
            } else {
                context.perform(.toggle, origin: "modern")
            }
        case .stop: context.perform(.stop, origin: "modern")
        case .next: context.perform(.next, origin: "modern")
        case .previous: context.perform(.previous, origin: "modern")
        case .seek(let fraction): if controller.snapshot.canSeek { controller.seek(toFraction: fraction) }
        case .volume(let v): context.setVolume(min(max(v, 0), 1) * 100)
        case .favourite: context.toggleFavourite()
        case .retry: context.retry()
        case .toggleTimeDisplay: context.updateSettings { $0.timeRemaining.toggle() }
        case .cycleVisualizer:
            // While rotating, the artwork skips to its next scene by itself.
            if modernVisualizer != .rotate { setModernVisualizer(modernVisualizer.nextScene) }
        case .setVisualizer(let mode): setModernVisualizer(mode)
        case .setVisualizerInterval(let seconds):
            context.updateSettings { $0.visualizerInterval = min(max(seconds, 5), 600) }
            publishDebugState()
        case .setArtworkColors(let colors):
            context.updateSettings { $0.artworkColors = colors.rawValue }
            publishDebugState()
        case .setVisualizerEffect(let effect):
            context.updateSettings { $0.visualizerEffect = effect.rawValue }
            publishDebugState()
        case .toggleShuffle: context.toggleShuffle()
        case .toggleRepeat: context.toggleRepeat()
        case .genreMenu(let point): openGenreMenu(.marquee, at: point)
        case .moreMenu(let point), .contextMenu(let point):
            popUp(contextMenu(), at: point, kind: "context", anchor: nil)
        case .presetsMenu(let point): popUp(presetsMenu(), at: point, kind: "presets", anchor: nil)
        case .eqEnabled(let on):
            var eq = controller.equalizer
            eq.enabled = on
            context.setEqualizer(eq, preset: context.settings.eqPreset)
        case let .eqBand(index, db):
            guard (0..<EQSettings.bandCount).contains(index) else { return }
            var eq = controller.equalizer
            eq.bands[index] = Float(db)
            context.setEqualizer(eq, preset: nil)
        case .preamp(let db):
            var eq = controller.equalizer
            eq.preamp = Float(db)
            context.setEqualizer(eq, preset: nil)
        case .eqReset:
            applyPreset(EQPresets.flat)
        case .playStation(let row):
            guard let ids = playlistIDs(), row >= 0, row < ids.count else { return }
            controller.play(stream: ids[row])
        case .setAppearance(let appearance): setAppearance(appearance)
        case .setTint(let tint): setTint(tint)
        case .switchToClassic: onSwitchToClassic?()
        case .layoutChanged:
            // The View menu rebuilds itself when it opens.
            publishDebugState()
        case .close: context.onQuit?("main window closed")
        case .minimize: break
        }
        render()
    }

    func setAppearance(_ appearance: ModernAppearance) {
        player.appearance = appearance
        context.updateSettings { $0.modernAppearance = appearance.rawValue }
        publishDebugState()
    }

    func setTint(_ tint: ModernTint) {
        player.tint = tint
        context.updateSettings { $0.modernTint = tint.rawValue }
        publishDebugState()
    }

    var modernVisualizer: ModernPlayerState.Visualizer {
        ModernPlayerState.Visualizer(rawValue: context.settings.modernVisualizer) ?? .default
    }

    func setModernVisualizer(_ mode: ModernPlayerState.Visualizer) {
        context.updateSettings { $0.modernVisualizer = mode.rawValue }
        render()
        publishDebugState()
    }

    /// The station list's stream IDs in row order (what `playStation` indexes).
    func playlistIDs() -> [StreamID]? {
        let controller = context.controller
        let s = controller.snapshot
        return SkinDisplay.playlist(genre: s.genre, favouritesMode: s.favouritesMode, catalog: controller.catalog,
                                    favourites: controller.favouriteStreams, banned: controller.library.bannedSet).map(\.id)
    }

    // MARK: View menu

    @objc override dynamic func viewItems() -> [NSMenuItem] {
        let holder = NSMenu()
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearance.submenu = PlayerStyleHost.appearanceMenu(current: player.appearance, target: self,
                                                             action: #selector(appearanceChosen(_:)))
        holder.addItem(appearance)
        let tint = NSMenuItem(title: "Tint", action: nil, keyEquivalent: "")
        tint.submenu = PlayerStyleHost.tintMenu(current: player.tint, target: self, action: #selector(tintChosen(_:)))
        holder.addItem(tint)
        holder.addItem(.separator())
        add(holder, "Equalizer", #selector(viewToggleEqualizer(_:)), key: "g", modifiers: [.command, .option]).state =
            player.openPanels.contains(.equalizer) ? .on : .off
        add(holder, "Stations", #selector(viewToggleStations(_:)), key: "e", modifiers: [.command, .option]).state =
            player.openPanels.contains(.stations) ? .on : .off
        add(holder, "Always on Top", #selector(viewAlwaysOnTop(_:)), key: "a", modifiers: [.command, .option]).state =
            player.alwaysOnTop ? .on : .off
        holder.addItem(.separator())
        add(holder, "Time Remaining", #selector(viewTimeRemaining(_:))).state = context.settings.timeRemaining ? .on : .off
        let vis = NSMenuItem(title: "Visualizer", action: nil, keyEquivalent: "")
        vis.submenu = modernVisualizerMenu()
        holder.addItem(vis)
        let items = holder.items
        holder.removeAllItems()
        return items
    }

    @objc func appearanceChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let appearance = ModernAppearance(rawValue: raw) else { return }
        setAppearance(appearance)
    }

    @objc func tintChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tint = ModernTint(rawValue: raw) else { return }
        setTint(tint)
    }

    /// Every scene, Rotate (with how often) and Off, what colours the artwork, and the effect.
    func modernVisualizerMenu() -> NSMenu {
        let settings = context.settings
        return Self.visualizerMenu(current: modernVisualizer, interval: settings.visualizerInterval,
                                   colors: ArtworkColors(rawValue: settings.artworkColors) ?? .default,
                                   effect: ModernPlayerState.VisualizerEffect(rawValue: settings.visualizerEffect) ?? .default,
                                   target: self, choose: #selector(modernVisualizerChosen(_:)),
                                   every: #selector(visualizerIntervalChosen(_:)), background: #selector(artworkColorsChosen(_:)),
                                   finish: #selector(visualizerEffectChosen(_:)))
    }

    /// The View ▸ Visualizer menu, ticked: the scenes under their sections' headers, Rotate, Rotate Every ▸, Off,
    /// Background ▸, Effect ▸. Items carry the raw value (or the seconds) as their represented object.
    static func visualizerMenu(current: ModernPlayerState.Visualizer, interval: Double, colors: ArtworkColors,
                               effect: ModernPlayerState.VisualizerEffect, target: AnyObject, choose: Selector,
                               every: Selector, background: Selector, finish: Selector) -> NSMenu {
        let menu = NSMenu(title: "Visualizer")
        menu.autoenablesItems = false
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ object: Any, on: Bool) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = object
            item.state = on ? .on : .off
            return item
        }
        for section in ModernPlayerState.Visualizer.Section.allCases {
            menu.addItem(.sectionHeader(title: section.title))
            for mode in section.scenes {
                _ = item(menu, mode.title, choose, mode.rawValue, on: mode == current)
            }
        }
        menu.addItem(.separator())
        _ = item(menu, ModernPlayerState.Visualizer.rotate.title, choose, ModernPlayerState.Visualizer.rotate.rawValue,
                 on: current == .rotate)
        let intervals = NSMenu(title: "Rotate Every")
        intervals.autoenablesItems = false
        for seconds in ModernPlayerState.visualizerIntervals {
            _ = item(intervals, intervalTitle(seconds), every, seconds, on: abs(seconds - interval) < 0.5)
        }
        let rotateEvery = menu.addItem(withTitle: "Rotate Every", action: nil, keyEquivalent: "")
        rotateEvery.submenu = intervals
        _ = item(menu, ModernPlayerState.Visualizer.off.title, choose, ModernPlayerState.Visualizer.off.rawValue, on: current == .off)
        menu.addItem(.separator())
        let schemes = NSMenu(title: "Background")
        schemes.autoenablesItems = false
        for scheme in ArtworkColors.allCases {
            item(schemes, scheme.title, background, scheme.rawValue, on: scheme == colors).toolTip = scheme.help
        }
        let backgroundItem = menu.addItem(withTitle: "Background", action: nil, keyEquivalent: "")
        backgroundItem.submenu = schemes
        let effects = NSMenu(title: "Effect")
        effects.autoenablesItems = false
        for option in ModernPlayerState.VisualizerEffect.allCases {
            item(effects, option.title, finish, option.rawValue, on: option == effect).toolTip = option.help
        }
        let effectItem = menu.addItem(withTitle: "Effect", action: nil, keyEquivalent: "")
        effectItem.submenu = effects
        return menu
    }

    /// `10 Seconds`, `1 Minute`.
    static func intervalTitle(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s % 60 == 0 { return s == 60 ? "1 Minute" : "\(s / 60) Minutes" }
        return "\(s) Seconds"
    }

    @objc func modernVisualizerChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ModernPlayerState.Visualizer(rawValue: raw) else { return }
        setModernVisualizer(mode)
    }

    @objc func visualizerIntervalChosen(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        handle(.setVisualizerInterval(seconds))
    }

    @objc func visualizerEffectChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let effect = ModernPlayerState.VisualizerEffect(rawValue: raw) else { return }
        handle(.setVisualizerEffect(effect))
    }

    @objc func artworkColorsChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let colors = ArtworkColors(rawValue: raw) else { return }
        handle(.setArtworkColors(colors))
    }

    @objc func viewToggleEqualizer(_ sender: Any?) { player.togglePanel(.equalizer) }
    @objc func viewToggleStations(_ sender: Any?) { player.togglePanel(.stations) }
    @objc func viewAlwaysOnTop(_ sender: Any?) { player.setAlwaysOnTop(!player.alwaysOnTop) }
    @objc func viewTimeRemaining(_ sender: Any?) {
        context.updateSettings { $0.timeRemaining.toggle() }
        render()
        publishDebugState()
    }

    // MARK: Debug state

    /// Why the visualiser is or isn't drawing, and the output latency the analyser reads back by.
    var visualizerDetail: String {
        let latency = context.controller.renderBridge.map { String(format: "%.0f ms", $0.latencySeconds * 1000) } ?? "no audio yet"
        return player.visualizerDiagnostics + ", output latency \(latency)"
    }

    override func publishDebugState() {
        let f = player.window.frame
        let windows = ["main": AppUIDebugInfo.Window(open: true, shaded: false, visible: player.window.isVisible,
                                                     frame: [f.minX, f.minY, f.width, f.height])]
        let eq = context.controller.equalizer
        let settings = context.settings
        let ui = AppUIDebugInfo(
            mode: modeName, windows: windows, alwaysOnTop: player.alwaysOnTop, menuAutoOpened: menuAutoOpened,
            openMenu: openMenuKind,
            equalizer: .init(enabled: eq.enabled, auto: settings.eqAuto, preamp: Double(eq.preamp),
                             bands: eq.bands.map(Double.init), preset: settings.eqPreset),
            timeDisplay: settings.timeRemaining ? "remaining" : "elapsed", visualizerMode: settings.modernVisualizer,
            lastSheet: lastSheet, sheetOpen: sheetOpen, skinClass: "modern", appearance: player.appearance.rawValue,
            tint: player.tint.rawValue, panels: ModernPanel.allCases.filter(player.openPanels.contains).map(\.rawValue),
            visualizerInterval: settings.visualizerInterval, artworkColors: settings.artworkColors,
            visualizerEffect: settings.visualizerEffect, visualizerRunning: player.isVisualizerRunning,
            visualizerDetail: visualizerDetail)
        let skin = AppSkinDebugInfo(id: SkinLibrary.modernID, name: SkinLibrary.modernName, origin: "modern")
        context.controller.setShellState(skin: skin, ui: ui)
    }

    /// Quit path or a switch to the classic skins: stop observers and the display link, save the layout, hide.
    func close() {
        cancelMenuTracking()
        if let snapshotObserver { context.removeObserver(snapshotObserver) }
        snapshotObserver = nil
        if let sheet = player.window.attachedSheet { player.window.endSheet(sheet) }
        player.close()
    }
}

extension ModernPlayerUI: NSWindowDelegate {
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { context.undoManager }
}

// MARK: - PlayerFrontEnd and automation

extension ModernPlayerUI: PlayerFrontEnd {
    var modeName: String { "modern" }

    /// Skin files are classic skins: the host switches to them (this front end never loads one).
    func loadSkinFiles(_ paths: [String], origin: String) {}

    func automationPress(_ control: AutomationScript.Control) {
        switch control {
        case .play: player.press(.play)
        case .pause: player.press(.pause)
        case .stop: player.press(.stop)
        case .next: player.press(.next)
        case .previous: player.press(.previous)
        case .playPause: player.press(.playPause)
        case .retry: context.retry()
        }
    }

    func automationSetVolume(_ v: Double) {
        player.drag(.volume, to: v / 100)
    }

    /// The window as it shows on screen (glass included), as a PNG.
    func snapshot(to url: URL) throws {
        guard let image = player.capture(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw SkinPicture.Failure(description: "the window could not be captured (is it on screen?)") }
        try png.write(to: url, options: .atomic)
    }

    var automationReport: [String: Any] {
        var report = menuReport
        report["skinId"] = SkinLibrary.modernID
        report["skinClass"] = "modern"
        report["visualizer"] = ["running": player.isVisualizerRunning, "ticks": player.visualizerTicks,
                                "peak": Double(player.visualizerPeak), "scene": player.visualizerScene?.rawValue ?? "none",
                                "why": player.visualizerDiagnostics]
        return report
    }

    func automationDidFinish() {
        cancelMenuTracking()
        if let sheet = player.window.attachedSheet { player.window.endSheet(sheet) }
        player.close()
    }

    /// pressControl names are `ModernControl`s (`play`, `next`, `favourite`, `eqToggle`, `equalizerButton`, …);
    /// dragSlider takes `volume` and `position` (0…1), `preamp` and `band0`…`band9` (dB). The window is ignored.
    func perform(_ step: ShellAutomationScript.SkinStep) async -> (Bool, String?) {
        if let result = await performMenuStep(step) { return result }
        switch step {
        case .pressControl(let name, _):
            guard let control = ModernControl(rawValue: name) else { return (false, "unknown control \(name)") }
            return player.press(control) ? (true, nil) : (false, "\(name) did nothing")
        case let .dragSlider(name, value, _):
            let control: ModernControl
            let fraction: Double
            switch name {
            case "volume", "position":
                control = name == "volume" ? .volume : .position
                fraction = value
            case "preamp":
                control = .preamp
                fraction = ModernPlayer.eqFraction(decibels: value)
            default:
                guard name.hasPrefix("band"), let i = Int(name.dropFirst(4)), (0..<10).contains(i) else {
                    return (false, "unknown slider \(name)")
                }
                control = ModernControl.bands[i]
                fraction = ModernPlayer.eqFraction(decibels: value)
            }
            return player.drag(control, to: fraction) ? (true, nil) : (false, "\(name) is not a working slider now")
        case .showWindows:
            player.show(activate: false)
            publishDebugState()
            return (true, nil)
        case .playRow(let row):
            return player.playStation(row) ? (true, nil) : (false, "no station row \(row)")
        case .loadSkin:
            return (false, "loadSkin goes through the host")
        default:
            return (false, "\(step) is not handled")
        }
    }
}
