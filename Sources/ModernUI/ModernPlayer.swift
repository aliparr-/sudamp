// SPDX-License-Identifier: GPL-3.0-or-later
// The modern skin's window, as the app sees it: give it a `ModernPlayerState`, an appearance and a tint, and
// listen to `onEvent`. It owns the panels (Equalizer, Stations), the window's place (`modern-layout.json`), the
// visualiser's display link (30 Hz, only while the artwork animates and the window can be seen), the appearance
// popover, and the hooks automation and snapshots use.

import AppKit
import QuartzCore

public final class ModernPlayer: NSObject {
    public struct Configuration {
        /// Where the window's place and open panels are saved; nil disables persistence.
        public var layoutURL: URL?
        public var appearance: ModernAppearance = .default
        public var tint: ModernTint = .default
        /// Panels open when there is no saved layout.
        public var initialPanels: Set<ModernPanel> = []
        public init() {}
    }

    public let window: ModernWindow
    private let root: ModernRootView
    private let configuration: Configuration
    private var displayLink: CADisplayLink?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var popover: NSPopover?
    private var saveTask: Task<Void, Never>?

    public var state = ModernPlayerState() {
        didSet {
            guard state != oldValue else { return }
            root.nowPlaying.apply(state: state)
            root.equalizer.apply(equalizer: state.equalizer)
            root.stations.apply(stations: state.stations, current: state.currentStation, title: state.stationsTitle,
                                playing: state.playback == .playing)
            updateDisplayLink()
        }
    }

    public var appearance: ModernAppearance {
        didSet { if appearance != oldValue { applyAppearance() } }
    }

    public var tint: ModernTint {
        didSet { if tint != oldValue { applyPalette() } }
    }

    /// Visualiser frames, pulled at 30 Hz while the artwork animates.
    public var visualizerProvider: ModernVisualizerProvider?
    /// Every user action.
    public var onEvent: ((ModernEvent) -> Void)?
    /// Skin files (`.wsz`, `.zip`) dropped on the window. Returns whether they were taken.
    public var onFilesDropped: (([URL]) -> Bool)? {
        didSet { root.onFilesDropped = onFilesDropped }
    }
    /// Keep the visualiser running while the window is covered (measurements only).
    public var pausesWhenOccluded = true {
        didSet { updateDisplayLink() }
    }

    public var openPanels: Set<ModernPanel> { root.openPanels }
    public var alwaysOnTop: Bool { window.level == .floating }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        appearance = configuration.appearance
        tint = configuration.tint
        let layout = configuration.layoutURL.flatMap(ModernLayout.load(from:))
        let panels = layout?.openPanels ?? configuration.initialPanels
        let size = ModernGeometry.windowSize(open: panels)
        window = ModernWindow(size: size)
        root = ModernRootView(frame: CGRect(origin: .zero, size: size))
        super.init()
        window.contentView = root
        window.level = layout?.alwaysOnTop == true ? .floating : .normal
        root.onEvent = { [weak self] event in self?.handle(event) }
        window.onClose = { [weak self] in self?.handle(.close) }
        root.onResize = { [weak self] size in self?.resizeWindow(to: size) }
        root.nowPlaying.onEvent = { [weak self] event in self?.handle(event) }
        root.nowPlaying.onPanelButton = { [weak self] panel in self?.togglePanel(panel) }
        root.nowPlaying.onAppearanceButton = { [weak self] view in self?.showAppearancePopover(from: view) }
        root.equalizer.onEvent = { [weak self] event in self?.handle(event) }
        root.stations.onEvent = { [weak self] event in self?.handle(event) }
        root.setPanels(panels, animated: false)
        place(layout: layout, size: size)
        applyAppearance()
        startObservers()
        window.makeFirstResponder(root)
    }

    // MARK: Showing

    public func show(activate: Bool = true) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        let first = !window.isVisible
        if first, !Motion.reduced { window.alphaValue = 0 }
        if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
        if first, !Motion.reduced {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.28
                window.animator().alphaValue = 1
            }, completionHandler: { MainActor.assumeIsolated { self.updateDisplayLink() } })
        }
        updateDisplayLink()
    }

    /// For logs: why the visualiser is or isn't running.
    public var visualizerDiagnostics: String {
        "animating \(state.isAnimating), mode \(state.visualizer.rawValue), visible \(window.isVisible), "
            + "occlusion visible \(window.occlusionState.contains(.visible)), link paused \(displayLink?.isPaused ?? true)"
    }

    /// Fades out and hides (switching skins).
    public func hide(animated: Bool, completion: (@MainActor () -> Void)? = nil) {
        popover?.close()
        guard animated, window.isVisible, !Motion.reduced else {
            window.orderOut(nil)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated {
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            completion?()
        } })
    }

    /// Stops the display link and observers, saves the layout and hides the window. Final.
    public func close() {
        saveLayout()
        popover?.close()
        displayLink?.invalidate()
        displayLink = nil
        root.stopAnimations()
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        saveTask?.cancel()
        window.orderOut(nil)
    }

    public func minimize() { window.miniaturize(nil) }

    public func setAlwaysOnTop(_ on: Bool) {
        window.level = on ? .floating : .normal
        layoutChanged()
    }

    // MARK: Panels

    public func setPanel(_ panel: ModernPanel, open: Bool, animated: Bool = true) {
        var panels = root.openPanels
        if open { panels.insert(panel) } else { panels.remove(panel) }
        root.setPanels(panels, animated: animated)
        layoutChanged()
    }

    public func togglePanel(_ panel: ModernPanel) {
        setPanel(panel, open: !root.openPanels.contains(panel))
    }

    private func resizeWindow(to size: CGSize) {
        let f = window.frame
        // Keep the top-left: the player stays where it is.
        window.setFrame(CGRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: Appearance

    private func applyAppearance() {
        window.appearance = appearance.nsAppearance
        applyPalette()
    }

    private func applyPalette() {
        let palette = ModernPalette(tint: tint, appearance: window.effectiveAppearance)
        root.apply(palette)
        root.nowPlaying.apply(state: state, force: true)
    }

    private func showAppearancePopover(from view: NSView) {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let controller = AppearancePopover(appearance: appearance, tint: tint)
        controller.onEvent = { [weak self] event in
            if case .switchToClassic = event { self?.popover?.close() }
            self?.handle(event)
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = !Motion.reduced
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        self.popover = popover
    }

    public var isAppearancePopoverShown: Bool { popover?.isShown ?? false }

    /// Opens the appearance popover as its button would (automation, the preview).
    public func showAppearancePopover() {
        if popover?.isShown != true { showAppearancePopover(from: root.nowPlaying.appearanceButton) }
    }

    /// The popover's window while it shows (captures).
    public var popoverWindow: NSWindow? { popover?.isShown == true ? popover?.contentViewController?.view.window : nil }

    // MARK: Events

    private func handle(_ event: ModernEvent) {
        switch event {
        case .close where onEvent == nil: close()
        case .minimize: minimize()
        default: break
        }
        onEvent?(event)
    }

    /// Saves the layout after a short pause; reports the change now, or (window moves) once it has settled.
    private func layoutChanged(settled: Bool = false) {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.saveLayout()
            if settled { self.onEvent?(.layoutChanged) }
        }
        if !settled { onEvent?(.layoutChanged) }
    }

    // MARK: Layout

    public var currentLayout: ModernLayout {
        let f = window.frame
        return ModernLayout(x: Double(f.minX), top: Double(f.maxY), panels: ModernPanel.allCases.filter(openPanels.contains).map(\.rawValue),
                            alwaysOnTop: alwaysOnTop)
    }

    public func saveLayout() {
        guard let url = configuration.layoutURL else { return }
        try? currentLayout.save(to: url)
    }

    /// The saved place if it is still on a screen; else the upper middle of the main screen.
    private func place(layout: ModernLayout?, size: CGSize) {
        if let layout {
            let frame = CGRect(x: layout.x, y: layout.top - size.height, width: size.width, height: size.height)
            let visible = frame.insetBy(dx: Metrics.margin + 40, dy: Metrics.margin + 40)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(visible) }) {
                window.setFrame(frame, display: false)
                return
            }
        }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let top = screen.maxY - screen.height * 0.18 + Metrics.margin
        window.setFrame(CGRect(x: screen.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                        display: false)
    }

    // MARK: Visualiser

    private func startObservers() {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDisplayLink() }
        }))
        // Moves arrive continuously while dragging: saved and reported once they settle.
        observers.append((center, center.addObserver(forName: NSWindow.didMoveNotification, object: window,
                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutChanged(settled: true) }
        }))
        root.onAppearanceChange = { [weak self] in self?.applyPalette() }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPalette()
                self?.root.nowPlaying.refreshMotion()
                self?.root.stations.refreshMotion()
            }
        }))
        let link = root.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        displayLink = link
    }

    private var visualizerWanted: Bool {
        guard state.isAnimating, state.visualizer != .off, window.isVisible, !window.isMiniaturized else { return false }
        return !pausesWhenOccluded || window.occlusionState.contains(.visible)
    }

    private func updateDisplayLink() {
        guard let displayLink else { return }
        let wanted = visualizerWanted
        if displayLink.isPaused == wanted { displayLink.isPaused = !wanted }
        if !wanted { root.nowPlaying.artwork.update(with: nil) }
    }

    public var isVisualizerRunning: Bool { displayLink.map { !$0.isPaused } ?? false }
    public private(set) var visualizerTicks = 0

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        visualizerTicks += 1
        root.nowPlaying.artwork.update(with: visualizerProvider?())
    }

    // MARK: Anchors, automation, capture

    /// Where the genre menu opens: under the genre button.
    public func genreMenuAnchor() -> CGPoint { root.nowPlaying.genreButton.menuAnchorBelow }
    public func moreMenuAnchor() -> CGPoint { root.nowPlaying.moreButton.menuAnchorBelow }
    /// Under the presets button (the Equalizer opens first if it is closed).
    public func presetsMenuAnchor() -> CGPoint {
        if !openPanels.contains(.equalizer) { setPanel(.equalizer, open: true, animated: false) }
        root.equalizer.layoutSubtreeIfNeeded()
        return root.equalizer.presetsButton.menuAnchorBelow
    }

    /// Presses a control as a click would. False when it is disabled or not there.
    @discardableResult
    public func press(_ control: ModernControl) -> Bool {
        let np = root.nowPlaying
        func click(_ button: GlyphButton) -> Bool {
            guard button.isEnabled else { return false }
            button.performPress()
            return true
        }
        switch control {
        case .play:
            return state.playback == .playing || state.working ? true : click(np.playButton)
        case .pause:
            return state.playback == .playing || state.working ? click(np.playButton) : false
        case .playPause: return click(np.playButton)
        case .stop:
            onEvent?(.stop)
            return true
        case .next: return click(np.nextButton)
        case .previous: return click(np.previousButton)
        case .favourite: return click(np.favouriteButton)
        case .genre:
            np.genreButton.performPress()
            return true
        case .more: return click(np.moreButton)
        case .retry:
            guard !np.retryButton.isHidden else { return false }
            np.retryButton.performPress()
            return true
        case .equalizerButton: return click(np.equalizerButton)
        case .stationsButton: return click(np.stationsButton)
        case .appearanceButton: return click(np.appearanceButton)
        case .eqToggle:
            root.equalizer.toggle.toggle()
            return true
        case .presets:
            root.equalizer.presetsButton.performPress()
            return true
        case .eqReset: return click(root.equalizer.resetButton)
        case .volume, .position, .preamp, .eq0, .eq1, .eq2, .eq3, .eq4, .eq5, .eq6, .eq7, .eq8, .eq9:
            return false
        }
    }

    /// Drags a slider to `fraction` (0...1) as a user would. False when it is disabled or not a slider.
    @discardableResult
    public func drag(_ control: ModernControl, to fraction: Double) -> Bool {
        switch control {
        case .volume: return root.nowPlaying.volume.drag(to: fraction)
        case .position: return state.canSeek && root.nowPlaying.progress.drag(to: fraction)
        case .preamp: return root.equalizer.preamp.drag(to: fraction)
        default:
            guard let i = control.bandIndex else { return false }
            return root.equalizer.bands[i].drag(to: fraction)
        }
    }

    /// An EQ slider's position (0...1) for a gain in dB (-12...12).
    public nonisolated static func eqFraction(decibels: Double) -> Double { EQCurve.value(decibels: decibels) }

    /// Plays a station row as a double-click would.
    @discardableResult
    public func playStation(_ row: Int) -> Bool { root.stations.play(row: row) }

    /// The window as it looks on screen (glass included: own windows need no Screen Recording permission). With
    /// `below`, the windows under it too (the preview's backdrop); nil when capture isn't possible.
    public func capture(below: Bool = false) -> CGImage? {
        // With the popover up, capture from it down so it is included.
        if let popover = popoverWindow {
            return WindowCapture.image(of: popover, below: true, rect: window.frame.union(popover.frame))
        }
        return WindowCapture.image(of: window, below: below)
    }

    /// The scrolling title is moving.
    public var isTitleScrolling: Bool { root.nowPlaying.titleView.isAnimating }
}

/// Own-window capture through CGWindowListCreateImage: obsoleted in the macOS 15 SDK but still exported, so it is
/// looked up at run time as spike S1 and the classic preview do (ScreenCaptureKit would need Screen Recording
/// permission).
enum WindowCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func image(of window: NSWindow, below: Bool, rect frame: CGRect? = nil) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let f = frame ?? window.frame
        let rect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        let list = below ? CGWindowListOption.optionOnScreenBelowWindow.rawValue | CGWindowListOption.optionIncludingWindow.rawValue
            : CGWindowListOption.optionIncludingWindow.rawValue
        let options = CGWindowImageOption.bestResolution.rawValue
        return create(rect, list, UInt32(window.windowNumber), options)?.takeRetainedValue()
    }
}

/// Development views (the preview's contact sheets).
public enum ModernDebug {
    /// A grid of artworks: one row per genre key, light and dark, playing (the light drifting).
    public static func artworkSheet(genreKeys: [String?], tint: ModernTint, size: CGFloat = 92) -> NSView {
        let gap: CGFloat = 24
        let columns = 2
        let view = FlippedView(frame: CGRect(x: 0, y: 0, width: (size + gap) * CGFloat(columns) + gap,
                                             height: (size + gap) * CGFloat(genreKeys.count) + gap))
        view.wantsLayer = true
        for (row, key) in genreKeys.enumerated() {
            for column in 0..<columns {
                let dark = column == 1
                let art = ArtworkView(frame: CGRect(x: gap + CGFloat(column) * (size + gap), y: gap + CGFloat(row) * (size + gap),
                                                    width: size, height: size))
                art.cornerRadius = 16
                art.setDark(dark)
                art.palette = ArtworkPalette.make(genreKey: key, tint: tint, dark: dark)
                view.addSubview(art)
                art.update(with: ModernVisualizerFrame(bars: (0..<19).map { Float(0.25 + 0.6 * abs(sin(Double($0) * 0.55))) },
                                                       scope: (0..<76).map { Float(sin(Double($0) / 6)) }))
            }
        }
        return view
    }
}
