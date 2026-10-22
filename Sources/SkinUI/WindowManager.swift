// SPDX-License-Identifier: GPL-3.0-or-later
//
// Owns the Main, Equalizer and Playlist SkinWindows (DESIGN §8.1, PLAN M5 "window management"):
//
// - docking: dragging Main carries its docked cluster (attached as child windows only for the drag), other
//   windows move alone; everything snaps to the other windows and the screen edges at 15 points
//   (DockingGeometry over SkinKit's SnapGeometry);
// - shade (Main and EQ; what hangs below follows), uniform scale 1/2/3 (rescaled around Main's top-left so
//   docked windows stay docked), always on top, opening and closing EQ and Playlist, minimise-all;
// - layout persistence to a JSON file (WindowLayout), restored at launch;
// - screen guard: after display changes or wake, stranded docked groups move back on screen as a unit;
// - runtime skin switching and the region.txt kill switch.
//
// The player state goes in through `playerState`; every SkinControlEvent comes out through `onEvent`, after
// the window-level ones (shade, minimise, EQ/PL toggles and closes, clutter A and D) have been applied here
// when `handlesWindowEvents` is on.
//
// Behaviour adapted from Bitamp's WindowGroup (ryanromanov/Bitamp @ 91952819, MIT © 2026 Ryan Romanosky and
// Bitamp contributors: group drag, minimise, scale around Main's top-left) and MacAmp's WindowSnapManager and
// WindowScreenGuard (hfyeomans/MacAmp @ cb0c77f, MIT © 2025-2026 Hank Yeomans: settle delays after display
// changes and wake, addObserver(forName:) for macOS 15). No code is copied verbatim; the geometry and its
// notices are in DockingGeometry.swift.
//
// Notices: Bitamp — MIT License, Copyright (c) 2026 Ryan Romanosky and Bitamp contributors; MacAmp — MIT License,
// Copyright (c) 2025-2026 Hank Yeomans.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import AppKit
import SkinKit

public final class WindowManager {
    public struct Configuration {
        /// Explicit scale (e.g. `--scale`); nil: the saved layout's, else 2 on Retina and 1 otherwise.
        public var scale: Int?
        /// Windows open on first launch (DESIGN §3: Main and Playlist). Main is always open.
        public var initialOpen: Set<SkinWindowRole> = [.main, .playlist]
        /// Where the layout is saved; nil disables persistence.
        public var layoutURL: URL?
        /// false: never orders windows on screen and starts no observers (tests drive the geometry headlessly).
        public var ordersWindows = true
        /// region.txt shaping (spike S1 kill switch).
        public var regionEnabled = true
        /// Apply shade, minimise, EQ/PL toggles, EQ/PL close and clutter A/D here before forwarding.
        public var handlesWindowEvents = true
        /// Screens in top-left space; nil reads NSScreen.screens.
        public var screens: (@MainActor () -> [DockScreen])?
        /// Quiet period after the last display change before clamping (MacAmp: 1 s).
        public var screenSettleDelay: Double = 1.0
        /// Settle time after wake, when displays come back one by one (MacAmp: 3 s).
        public var wakeSettleDelay: Double = 3.0

        public init() {}
    }

    public let windows: [SkinWindowRole: SkinWindow]
    public private(set) var skin: Skin
    public private(set) var scale: Int
    public private(set) var alwaysOnTop = false
    public private(set) var regionEnabled: Bool
    public private(set) var openWindows: Set<SkinWindowRole>
    public private(set) var shadedWindows: Set<SkinWindowRole>
    /// Set when the last layout write failed.
    public private(set) var lastSaveError: String?

    /// What every window shows.
    public var playerState = SkinPlayerState() {
        didSet {
            guard playerState != oldValue else { return }
            for window in windows.values { window.skinView.playerState = playerState }
        }
    }

    /// Visualiser frames for the main window (and its shade strip), pulled at 30 Hz.
    public var visualizerProvider: VisualizerProvider? {
        didSet { windows[.main]?.skinView.visualizerProvider = visualizerProvider }
    }

    /// Stop animating windows that are fully occluded (default). Off only for measurements.
    public var pausesWhenOccluded = true {
        didSet { for window in windows.values { window.skinView.pausesWhenOccluded = pausesWhenOccluded } }
    }

    /// Every control event, with the window it came from.
    public var onEvent: ((SkinControlEvent, SkinWindowRole) -> Void)?
    /// Called after windows moved, opened, closed, shaded or rescaled (after the layout file was written).
    public var onLayoutChange: (() -> Void)?
    /// Skin files dropped on any window, with the window they landed on. Returns whether they were taken.
    public var onFilesDropped: (([URL], SkinWindowRole) -> Bool)? {
        didSet {
            for (role, window) in windows {
                window.skinView.onFileDrop = onFilesDropped.map { handler in { urls in handler(urls, role) } }
            }
        }
    }

    private let configuration: Configuration
    private var drag: DockDrag?
    private var dragChildren: [SkinWindow] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var settleTask: Task<Void, Never>?
    private var openBeforeMinimize: Set<SkinWindowRole>?
    private var shown = false

    public init(skin: Skin, configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.skin = skin
        let layout = configuration.layoutURL.flatMap { WindowLayout.load(from: $0) }
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        scale = SkinScale.clamp(configuration.scale ?? layout?.scale ?? SkinScale.defaultScale(backingScaleFactor: backing))
        regionEnabled = configuration.regionEnabled
        alwaysOnTop = layout?.alwaysOnTop ?? false
        var open: Set<SkinWindowRole> = [.main]
        var shaded: Set<SkinWindowRole> = []
        for role in SkinWindowRole.allCases {
            if let entry = layout?.entry(role) {
                if entry.open { open.insert(role) }
                if entry.shaded, role.supportsShade { shaded.insert(role) }
            } else if configuration.initialOpen.contains(role) {
                open.insert(role)
            }
        }
        openWindows = open
        shadedWindows = shaded
        var built: [SkinWindowRole: SkinWindow] = [:]
        for role in SkinWindowRole.allCases {
            built[role] = SkinWindow(role: role, skin: skin, scale: scale, shaded: shaded.contains(role))
        }
        windows = built
        for window in windows.values {
            window.skinView.onOutput = { [weak self] output, view in self?.handle(output, from: view.role) }
            window.level = alwaysOnTop ? .floating : .normal
        }
        updateChrome()
        placeWindows(layout: layout)
        clampToScreens(save: false)
        if configuration.ordersWindows { startObservers() }
    }

    // MARK: Showing

    /// Orders the open windows on screen, Main key.
    public func show() {
        shown = true
        guard configuration.ordersWindows else { return }
        for role in [SkinWindowRole.playlist, .equalizer] where openWindows.contains(role) {
            windows[role]?.orderFront(nil)
        }
        windows[.main]?.makeKeyAndOrderFront(nil)
    }

    public func isOpen(_ role: SkinWindowRole) -> Bool { openWindows.contains(role) }

    /// Opens or closes the Equalizer or Playlist (Main stays open: closing it is the app's quit).
    public func setOpen(_ open: Bool, _ role: SkinWindowRole) {
        guard role != .main, open != openWindows.contains(role) else { return }
        if open {
            openWindows.insert(role)
            if shown, configuration.ordersWindows, openBeforeMinimize == nil { windows[role]?.orderFront(nil) }
        } else {
            openWindows.remove(role)
            if configuration.ordersWindows { windows[role]?.orderOut(nil) }
        }
        updateChrome()
        layoutChanged()
    }

    public func toggleOpen(_ role: SkinWindowRole) { setOpen(!isOpen(role), role) }

    // MARK: Shade, scale, level, skin

    public func isShaded(_ role: SkinWindowRole) -> Bool { shadedWindows.contains(role) }

    /// Main and EQ shade strips; the window keeps its top edge and what hangs below it follows.
    public func setShaded(_ shaded: Bool, _ role: SkinWindowRole) {
        guard role.supportsShade, shaded != shadedWindows.contains(role), let window = windows[role] else { return }
        if shaded { shadedWindows.insert(role) } else { shadedWindows.remove(role) }
        let kind = role.kind(shaded: shaded)
        let moved = DockingGeometry.resize(role, to: SkinScale.intSize(kind, scale: scale), frames: frames())
        window.skinView.configure(kind: kind)
        apply(moved)
        layoutChanged()
    }

    public func toggleShade(_ role: SkinWindowRole) { setShaded(!isShaded(role), role) }

    /// Uniform scale 1, 2 or 3, rescaled around Main's top-left so docked windows stay docked.
    public func setScale(_ newScale: Int) {
        let target = SkinScale.clamp(newScale)
        guard target != scale else { return }
        let old = scale
        scale = target
        let rescaled = DockingGeometry.rescale(frames(), sizes: sizes(), anchor: .main, oldScale: old, newScale: target)
        for window in windows.values { window.skinView.configure(scale: target) }
        apply(rescaled)
        updateChrome()
        clampToScreens(save: false)
        layoutChanged()
    }

    /// ⌘D / clutter D: 1x ↔ 2x (from 3x back to 1x).
    public func toggleScale() { setScale(scale == 1 ? 2 : 1) }

    /// 1 → 2 → 3 → 1.
    public func cycleScale() { setScale(scale >= 3 ? 1 : scale + 1) }

    public func setAlwaysOnTop(_ on: Bool) {
        alwaysOnTop = on
        for window in windows.values { window.level = on ? .floating : .normal }
        layoutChanged()
    }

    /// Switches every window to `newSkin` at run time (frames recompose, shadows are invalidated).
    public func setSkin(_ newSkin: Skin) {
        skin = newSkin
        for window in windows.values { window.skinView.configure(skin: newSkin) }
    }

    /// region.txt on/off (spike S1's kill switch: off gives rectangular, fully opaque windows).
    public func setRegionEnabled(_ on: Bool) {
        regionEnabled = on
        updateChrome()
    }

    public func scrollPlaylist(toRow row: Int) {
        windows[.playlist]?.skinView.scrollPlaylist(toRow: row)
    }

    /// Where a menu anchored "under the marquee" opens (DESIGN §3): the top-left of the menu at the bottom-left of
    /// Main's marquee, or under the shade strip's title text when Main is shaded. AppKit screen coordinates, ready
    /// for `NSMenu.popUp(positioning:at:in: nil)`; valid while the window is off screen too.
    public func marqueeMenuAnchor() -> CGPoint {
        guard let view = windows[.main]?.skinView else { return .zero }
        let rect = view.kind == .shade ? IntRect(6, 0, 160, 14) : MainLayout.marquee
        let screen = view.screenRect(forSkinRect: rect)
        return CGPoint(x: screen.minX, y: screen.minY)
    }

    /// Winamp's minimise: Main goes to the Dock and the other windows hide until it comes back.
    public func minimize() {
        guard configuration.ordersWindows, let main = windows[.main] else { return }
        openBeforeMinimize = openWindows
        for role in [SkinWindowRole.equalizer, .playlist] { windows[role]?.orderOut(nil) }
        main.miniaturize(nil)
    }

    private func mainDeminiaturized() {
        guard openBeforeMinimize != nil else { return }
        openBeforeMinimize = nil
        // Whatever is open now (EQ/PL may have been toggled from a menu meanwhile).
        for role in [SkinWindowRole.playlist, .equalizer] where openWindows.contains(role) { windows[role]?.orderFront(nil) }
    }

    private func updateChrome() {
        var chrome = SkinChrome()
        chrome.eqOpen = openWindows.contains(.equalizer)
        chrome.playlistOpen = openWindows.contains(.playlist)
        chrome.doubleSize = scale >= 2
        chrome.applyRegion = regionEnabled
        for window in windows.values { window.skinView.chrome = chrome }
    }

    // MARK: Geometry

    /// Every window's frame in top-left space (whole points).
    public func frames() -> DockingGeometry.Frames {
        windows.mapValues { DockingGeometry.topLeft($0.frame) }
    }

    /// Window sizes at the current scale and shade states.
    public func sizes() -> [SkinWindowRole: IntSize] {
        Dictionary(uniqueKeysWithValues: SkinWindowRole.allCases.map {
            ($0, SkinScale.intSize($0.kind(shaded: shadedWindows.contains($0)), scale: scale))
        })
    }

    public func screens() -> [DockScreen] {
        if let provider = configuration.screens { return provider() }
        return NSScreen.screens.map {
            DockScreen(frame: DockingGeometry.topLeft($0.frame), visible: DockingGeometry.topLeft($0.visibleFrame))
        }
    }

    func apply(_ frames: DockingGeometry.Frames) {
        for (role, rect) in frames {
            guard let window = windows[role] else { continue }
            window.setFrame(DockingGeometry.appKit(rect), display: window.isVisible)
        }
    }

    /// Restores saved places; otherwise stacks the windows under Main (open ones first) centred on the main screen.
    private func placeWindows(layout: WindowLayout?) {
        let sizes = sizes()
        var frames: DockingGeometry.Frames = [:]
        for role in SkinWindowRole.allCases {
            guard let entry = layout?.entry(role), let size = sizes[role] else { continue }
            frames[role] = DockingGeometry.topLeft(CGRect(x: entry.x, y: entry.top - Double(size.height),
                                                         width: Double(size.width), height: Double(size.height)))
        }
        if frames[.main] == nil {
            let classic: [SkinWindowRole] = [.main, .equalizer, .playlist]
            let order = classic.filter { openWindows.contains($0) } + classic.filter { !openWindows.contains($0) }
            let openHeight = order.filter { openWindows.contains($0) }.compactMap { sizes[$0]?.height }.reduce(0, +)
            let width = sizes[.main]?.width ?? 550
            let screen = screens().first?.visible ?? IntRect(0, -900, 1440, 875)
            let origin = IntPoint(screen.x + max(0, (screen.width - width) / 2),
                                  screen.y + max(0, (screen.height - openHeight) / 2))
            frames = DockingGeometry.stacked(mainTopLeft: origin, sizes: sizes, order: order)
        } else {
            for role in SkinWindowRole.allCases where frames[role] == nil {
                frames[role] = DockingGeometry.dockedBelowCluster(role, size: sizes[role]!, frames: frames)
            }
        }
        apply(frames)
    }

    /// Classic stack under Main (EQ, then Playlist), keeping Main where it is.
    public func regroup() {
        guard let main = frames()[.main] else { return }
        let classic: [SkinWindowRole] = [.main, .equalizer, .playlist]
        let order = classic.filter { openWindows.contains($0) } + classic.filter { !openWindows.contains($0) }
        apply(DockingGeometry.stacked(mainTopLeft: main.origin, sizes: sizes(), order: order))
        clampToScreens(save: false)
        layoutChanged()
    }

    /// Moves stranded docked groups back on screen as a unit (after display changes, wake, rescale, restore).
    public func clampToScreens(save: Bool = true) {
        let moved = DockingGeometry.clamp(frames(), visible: openWindows, visibleFrames: screens().map(\.visible))
        guard !moved.isEmpty else { return }
        apply(moved)
        if save { layoutChanged() }
    }

    // MARK: Dragging

    /// Starts a window drag at an AppKit screen point. Main carries its docked cluster.
    public func beginDrag(_ role: SkinWindowRole, mouse: CGPoint) {
        if drag != nil { endDrag() }
        let started = DockingGeometry.beginDrag(role, frames: frames(), mouse: DockingGeometry.topLeft(mouse))
        drag = started
        guard configuration.ordersWindows, role == .main, let main = windows[.main] else { return }
        for member in started.moving where member != .main {
            guard let child = windows[member], child.isVisible else { continue }
            main.addChildWindow(child, ordered: .above)
            dragChildren.append(child)
        }
    }

    public func continueDrag(mouse: CGPoint) {
        guard let drag else { return }
        let offset = DockingGeometry.dragOffset(drag, mouse: DockingGeometry.topLeft(mouse), frames: frames(),
                                                visible: openWindows, screens: screens())
        let attached = Set(dragChildren.map(\.role))
        for (role, rect) in DockingGeometry.apply(drag, offset: offset) where !attached.contains(role) {
            windows[role]?.setFrameOrigin(DockingGeometry.appKit(rect).origin)
        }
    }

    public func endDrag() {
        guard drag != nil else { return }
        if let main = windows[.main] {
            for child in dragChildren { main.removeChildWindow(child) }
        }
        dragChildren = []
        drag = nil
        layoutChanged()
    }

    public var isDragging: Bool { drag != nil }

    // MARK: Events

    private func handle(_ output: SkinInteractionOutput, from role: SkinWindowRole) {
        switch output {
        case .beginWindowDrag(let screen): beginDrag(role, mouse: screen)
        case .dragWindow(let screen): continueDrag(mouse: screen)
        case .endWindowDrag: endDrag()
        case .event(let event): handle(event, from: role)
        case .marqueeScrubBegan, .marqueeScrubEnded: break
        }
    }

    /// Applies window-level events (when configured) and forwards every event to `onEvent`.
    public func handle(_ event: SkinControlEvent, from role: SkinWindowRole) {
        if configuration.handlesWindowEvents {
            switch event {
            case .shade(let target): toggleShade(target)
            case .minimize: minimize()
            case .close(let target) where target != .main: setOpen(false, target)
            case .eqWindowToggle: toggleOpen(.equalizer)
            case .plToggle: toggleOpen(.playlist)
            case .clutter(.alwaysOnTop, _): setAlwaysOnTop(!alwaysOnTop)
            case .clutter(.doubleSize, _): toggleScale()
            default: break
            }
        }
        onEvent?(event, role)
    }

    // MARK: Persistence

    public func currentLayout() -> WindowLayout {
        var entries: [SkinWindowRole: WindowLayout.Entry] = [:]
        for (role, window) in windows {
            entries[role] = .init(x: Double(window.frame.minX), top: Double(window.frame.maxY),
                                  open: openWindows.contains(role), shaded: shadedWindows.contains(role))
        }
        return WindowLayout(scale: scale, alwaysOnTop: alwaysOnTop, windows: entries)
    }

    /// Writes the layout file now (also done after every layout change).
    public func saveLayout() {
        guard let url = configuration.layoutURL else { return }
        do {
            try currentLayout().save(to: url)
            lastSaveError = nil
        } catch {
            lastSaveError = "\(error)"
        }
    }

    private func layoutChanged() {
        saveLayout()
        onLayoutChange?()
    }

    // MARK: Screen guard

    private func startObservers() {
        let app = NotificationCenter.default
        let screenToken = app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleClamp(after: self?.configuration.screenSettleDelay ?? 1) }
        }
        observers.append((app, screenToken))
        let workspace = NSWorkspace.shared.notificationCenter
        let wakeToken = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleClamp(after: self?.configuration.wakeSettleDelay ?? 3) }
        }
        observers.append((workspace, wakeToken))
        let deminiaturizeToken = app.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: windows[.main],
                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mainDeminiaturized() }
        }
        observers.append((app, deminiaturizeToken))
    }

    /// Clamps once the displays have been quiet for `delay` seconds (each new event restarts the wait).
    private func scheduleClamp(after delay: Double) {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.clampToScreens()
        }
    }

    /// Stops observers and display links and hides the windows.
    public func close() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        settleTask?.cancel()
        settleTask = nil
        if drag != nil { endDrag() }
        for window in windows.values {
            window.skinView.stopDisplayLink()
            if configuration.ordersWindows { window.orderOut(nil) }
        }
    }

    /// One line per window for logs: role, AppKit frame, open/shaded.
    public func describeFrames() -> String {
        SkinWindowRole.allCases.compactMap { role -> String? in
            guard let window = windows[role] else { return nil }
            let f = window.frame
            return "\(role) frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
                + " open=\(openWindows.contains(role)) shaded=\(shadedWindows.contains(role))"
                + " visible=\(window.isVisible) scale=\(scale)"
        }.joined(separator: "\n")
    }
}
