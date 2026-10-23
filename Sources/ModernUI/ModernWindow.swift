// SPDX-License-Identifier: GPL-3.0-or-later
// The modern window: borderless and clear, so all you see is the glass cards and their shadows. Clicks on the clear
// margins reach whatever is underneath (WindowServer routes clicks on transparent pixels, spike S1). Drag it by any
// part of a card that isn't a control. The cards sit in one NSGlassEffectContainerView. A panel opens downwards from
// its top edge like a drawer and closes back up into it, so no card ever passes over another.

import AppKit
import QuartzCore

/// Where the window is and which panels are open (`<profile>/modern-layout.json`).
nonisolated public struct ModernLayout: Codable, Equatable, Sendable {
    /// AppKit frame: left edge and top edge, in screen points.
    public var x: Double
    public var top: Double
    public var panels: [String]
    public var alwaysOnTop: Bool

    public init(x: Double, top: Double, panels: [String] = [], alwaysOnTop: Bool = false) {
        self.x = x
        self.top = top
        self.panels = panels
        self.alwaysOnTop = alwaysOnTop
    }

    public var openPanels: Set<ModernPanel> { Set(panels.compactMap(ModernPanel.init(rawValue:))) }

    public static func load(from url: URL) -> ModernLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModernLayout.self, from: data)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// The cards' frames, pure and unit-tested. Root-view coordinates (flipped), margin included: the player on top, then
/// the Equalizer, then the stations.
nonisolated public enum ModernGeometry {
    public enum Card: CaseIterable, Sendable { case nowPlaying, equalizer, stations }

    static func height(_ card: Card) -> CGFloat {
        switch card {
        case .nowPlaying: Metrics.nowPlayingHeight
        case .equalizer: Metrics.equalizerHeight
        case .stations: Metrics.stationsHeight
        }
    }

    static func panel(_ card: Card) -> ModernPanel? {
        switch card {
        case .nowPlaying: nil
        case .equalizer: .equalizer
        case .stations: .stations
        }
    }

    /// Frames of the shown cards.
    public static func frames(open: Set<ModernPanel>) -> [Card: CGRect] {
        frames(presence: presence(open: open)).filter { card, _ in panel(card).map(open.contains) ?? true }
    }

    /// 1 for the player and each open panel, 0 for the closed ones.
    static func presence(open: Set<ModernPanel>) -> [Card: CGFloat] {
        Dictionary(uniqueKeysWithValues: Card.allCases.map { card in (card, panel(card).map { open.contains($0) ? 1 : 0 } ?? 1) })
    }

    /// Every card's frame for how far each one is open (0...1; the player is always 1). A panel opens downwards from
    /// its top edge like a drawer and closes back up into it: its top stays a gap below the card above, its height
    /// and the gap after it scale with how open it is, and the cards below follow. So no card ever passes over another.
    static func frames(presence: [Card: CGFloat]) -> [Card: CGRect] {
        var out: [Card: CGRect] = [:]
        var y = Metrics.margin
        for card in Card.allCases {
            let open = min(max(presence[card] ?? 0, 0), 1)
            out[card] = CGRect(x: Metrics.margin, y: y, width: Metrics.cardWidth, height: height(card) * open)
            y += (height(card) + Metrics.gap) * open
        }
        return out
    }

    /// The window's content size.
    public static func windowSize(open: Set<ModernPanel>) -> CGSize {
        let frames = frames(open: open).values
        let bottom = frames.map(\.maxY).max() ?? Metrics.margin
        return CGSize(width: Metrics.cardWidth + Metrics.margin * 2, height: bottom + Metrics.margin)
    }

    /// The player card's top-left inside the window (for placing the window by its visible card).
    public static var cardInset: CGFloat { Metrics.margin }
}

/// The panels' motion, pure and unit-tested: a critically damped spring (no bounce: a drawer that overshot would
/// open past its content, or close to less than nothing), most of the way there in a fifth of a second and settled in
/// half a second.
nonisolated enum CardSpring {
    static let duration = 0.5
    static let frequency = 15.0

    /// Progress 0...1 of the move at `t` (0...1 of `duration`): never past 1, and exactly 1 at the end.
    static func position(_ t: Double) -> Double {
        guard t < 1 else { return 1 }
        let x = frequency * max(t, 0) * duration
        let value = 1 - (1 + x) * exp(-x)
        // Fade the last sliver of the tail out so the last frame lands exactly.
        let settle = max(0, (t - 0.85) / 0.15)
        return value + (1 - value) * settle
    }

    /// A page's opacity at `t`: opening, it fades in once the drawer has some depth; closing, it is gone before the
    /// last quarter of the drawer has shut.
    static func fade(_ t: Double, from a: CGFloat, to b: CGFloat) -> CGFloat {
        guard a != b else { return b }
        let p = b > a ? min(max((t - 0.16) / 0.42, 0), 1) : min(max(t / 0.34, 0), 1)
        let eased = p * p * (3 - 2 * p)
        return a + (b - a) * CGFloat(eased)
    }

    static func interpolate(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
}

public final class ModernWindow: NSWindow {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .miniaturizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The cards draw their own soft shadows (they follow the cards as panels slide).
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        collectionBehavior = [.fullScreenNone]
        title = "sudamp"
        setAccessibilityTitle("sudamp")
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    /// ⌘W and the File menu's Close: a borderless window has no close button for AppKit to press, so it would beep.
    var onClose: (() -> Void)?

    override public func performClose(_ sender: Any?) {
        if let onClose { onClose() } else { orderOut(sender) }
    }

    /// ⌘M: likewise no minimise button to press.
    override public func performMiniaturize(_ sender: Any?) { miniaturize(sender) }

    /// Called with the first mouse-down the window receives (diagnostics: clicks are reaching it).
    var onFirstMouseDown: (() -> Void)?

    override public func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let first = onFirstMouseDown {
            onFirstMouseDown = nil
            first()
        }
        super.sendEvent(event)
    }
    /// Clear margins mean the frame is bigger than what shows: let it reach the menu bar's edge.
    override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The window's content: the cards, their shadows, and the panel animations.
final class ModernRootView: FlippedView {
    let shadows = CardShadowView()
    let nowPlaying = NowPlayingCard()
    let equalizer = EqualizerCard()
    let stations = StationsCard()
    private let container: NSView
    private let stack = FlippedView()
    private(set) var openPanels: Set<ModernPanel> = []
    /// How far each card is open right now (0...1), moving while a panel opens or closes.
    private var presence = ModernGeometry.presence(open: [])
    private var palette: ModernPalette?
    var onEvent: ((ModernEvent) -> Void)?
    /// Called when the panels need a different window size: before an opening animation, after a closing one.
    var onResize: ((CGSize) -> Void)?
    /// Light or dark changed (the system's, or the window's own).
    var onAppearanceChange: (() -> Void)?
    /// The pointer is over a card (screen point): the window checks once that clicks there reach it.
    var onHoverOverCard: ((CGPoint) -> Void)? {
        didSet { updateTrackingAreas() }
    }
    private var hoverArea: NSTrackingArea?

    /// Files dropped on the window (classic skins: the app switches to them). Returns whether they were taken.
    var onFilesDropped: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        if GlassCard.systemGlassAvailable, #available(macOS 26.0, *) {
            let glassContainer = NSGlassEffectContainerView(frame: frameRect)
            // Cards blend only where they touch: never, with the gaps between them.
            glassContainer.spacing = 0
            container = glassContainer
        } else {
            container = FlippedView(frame: frameRect)
        }
        super.init(frame: frameRect)
        wantsLayer = true
        shadows.frame = bounds
        shadows.autoresizingMask = [.width, .height]
        addSubview(shadows)
        container.frame = bounds
        container.autoresizingMask = [.width, .height]
        stack.frame = bounds
        stack.autoresizingMask = [.width, .height]
        stack.wantsLayer = true
        if #available(macOS 26.0, *), let glassContainer = container as? NSGlassEffectContainerView {
            glassContainer.contentView = stack
        } else {
            container.addSubview(stack)
        }
        addSubview(container)
        // Later subviews draw on top: panels slide out from under the player.
        for card in [stations, equalizer, nowPlaying] as [GlassCard] { stack.addSubview(card) }
        equalizer.isHidden = true
        stations.isHidden = true
        nowPlaying.setAccessibilityLabel("Player")
        equalizer.setAccessibilityLabel("Equalizer")
        stations.setAccessibilityLabel("Stations")
        registerForDraggedTypes([.fileURL])
        moveCards(animated: false)
    }

    // MARK: Drag and drop (classic skins)

    private func skinFiles(_ info: any NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        skinFiles(sender).isEmpty || onFilesDropped == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = skinFiles(sender)
        guard !files.isEmpty, let onFilesDropped else { return false }
        return onFilesDropped(files)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        shadows.apply(palette)
        nowPlaying.apply(palette)
        equalizer.apply(palette)
        stations.apply(palette)
    }

    func card(_ card: ModernGeometry.Card) -> GlassCard {
        switch card {
        case .nowPlaying: nowPlaying
        case .equalizer: equalizer
        case .stations: stations
        }
    }

    /// Opens and closes panels. Growing, the window grows first and the panels then open; shrinking, the panels close
    /// and the window shrinks after.
    func setPanels(_ open: Set<ModernPanel>, animated: Bool) {
        guard open != openPanels else { return }
        let old = openPanels
        openPanels = open
        nowPlaying.setPanelOpen(.equalizer, open.contains(.equalizer))
        nowPlaying.setPanelOpen(.stations, open.contains(.stations))
        let newSize = ModernGeometry.windowSize(open: open)
        let oldSize = ModernGeometry.windowSize(open: old)
        if newSize.height >= oldSize.height { onResize?(newSize) }
        moveCards(animated: animated && (window?.isVisible == true || animatesOffscreen)) { [weak self] in
            guard let self, self.openPanels == open else { return }
            if newSize.height < oldSize.height { self.onResize?(newSize) }
        }
    }

    private func moveCards(animated: Bool, completion: (@MainActor () -> Void)? = nil) {
        let target = ModernGeometry.presence(open: openPanels)
        for kind in ModernGeometry.Card.allCases where (target[kind] ?? 0) > 0 {
            let card = self.card(kind)
            guard card.isHidden else { continue }
            // Opens from nothing at its top edge, its page clear.
            presence[kind] = 0
            card.content.alphaValue = 0
            card.isHidden = false
        }
        let duration = animated ? (Motion.reduced ? 0.25 : CardSpring.duration) : 0
        guard duration > 0 else {
            cardAnimation = nil
            presence = target
            for kind in ModernGeometry.Card.allCases { card(kind).content.alphaValue = (target[kind] ?? 0) > 0 ? 1 : 0 }
            applyPresence()
            hideClosedCards()
            completion?()
            return
        }
        // Liquid Glass is drawn from each view's real frame, not from Core Animation's in-flight values, so the
        // cards' frames are stepped on every display frame (frames and opacity only: the pages don't relayout).
        cardAnimation = CardAnimation(
            from: presence, to: target,
            fromAlpha: Dictionary(uniqueKeysWithValues: ModernGeometry.Card.allCases.map { ($0, card($0).content.alphaValue) }),
            start: CACurrentMediaTime(), duration: duration, completion: completion)
        startCardLink()
    }

    /// Puts every shown card where `presence` says, with its page and shadow.
    private func applyPresence() {
        let frames = ModernGeometry.frames(presence: presence)
        for kind in ModernGeometry.Card.allCases {
            let card = self.card(kind)
            guard !card.isHidden, let frame = frames[kind] else { continue }
            if card.frame != frame { card.frame = frame }
            // The page glides a little as the drawer opens and closes, as if it were drawn along with it.
            card.pageOffset = -(1 - (presence[kind] ?? 1)) * 10
        }
        updateShadows()
    }

    private func hideClosedCards() {
        for kind in ModernGeometry.Card.allCases where (presence[kind] ?? 0) <= 0 { card(kind).isHidden = true }
    }

    private func updateShadows() {
        shadows.update(ModernGeometry.Card.allCases.compactMap { kind in
            let card = self.card(kind)
            guard !card.isHidden else { return nil }
            return CardShadowView.Card(id: ObjectIdentifier(card), frame: card.frame, opacity: Float(presence[kind] ?? 1))
        })
    }

    // MARK: Card animation

    private struct CardAnimation {
        var from: [ModernGeometry.Card: CGFloat]
        var to: [ModernGeometry.Card: CGFloat]
        var fromAlpha: [ModernGeometry.Card: CGFloat]
        var start: CFTimeInterval
        var duration: Double
        var completion: (@MainActor () -> Void)?
    }

    private var cardAnimation: CardAnimation?
    private var cardLink: CADisplayLink?

    private func startCardLink() {
        if cardLink == nil {
            let link = displayLink(target: self, selector: #selector(cardLinkFired(_:)))
            link.add(to: .main, forMode: .common)
            cardLink = link
        }
        cardLink?.isPaused = false
        stepCards(at: CACurrentMediaTime())
    }

    @objc private func cardLinkFired(_ link: CADisplayLink) {
        stepCards(at: CACurrentMediaTime())
    }

    /// Tests: animate panels in a window that was never ordered on screen, stepping them with `stepCards(at:)`.
    var animatesOffscreen = false
    /// When the running panel animation started.
    var cardAnimationStart: CFTimeInterval? { cardAnimation?.start }

    func stepCards(at now: CFTimeInterval) {
        guard let animation = cardAnimation else {
            cardLink?.isPaused = true
            return
        }
        let t = min(max((now - animation.start) / animation.duration, 0), 1)
        for kind in ModernGeometry.Card.allCases {
            let from = animation.from[kind] ?? 0, to = animation.to[kind] ?? 0
            // Reduce Motion: nothing moves; a panel appears at once and fades in, or fades out and then goes.
            let move = Motion.reduced ? (to >= from || t >= 1 ? 1 : 0) : CardSpring.position(t)
            presence[kind] = CardSpring.interpolate(from, to, move)
            card(kind).content.alphaValue = CardSpring.fade(t, from: animation.fromAlpha[kind] ?? 0, to: to > 0 ? 1 : 0)
        }
        applyPresence()
        guard t >= 1 else { return }
        finishCardAnimation()
    }

    private func finishCardAnimation() {
        guard let animation = cardAnimation else { return }
        presence = animation.to
        for kind in ModernGeometry.Card.allCases { card(kind).content.alphaValue = (animation.to[kind] ?? 0) > 0 ? 1 : 0 }
        applyPresence()
        hideClosedCards()
        cardAnimation = nil
        cardLink?.isPaused = true
        animation.completion?()
    }

    /// Whether a panel is opening or closing (tests, automation).
    var isAnimatingCards: Bool { cardAnimation != nil }

    /// Final: the display link holds this view, so it must be invalidated when the window goes.
    func stopAnimations() {
        if var animation = cardAnimation {
            // Land, without the completion (the window is going).
            animation.completion = nil
            cardAnimation = animation
            finishCardAnimation()
        }
        cardLink?.invalidate()
        cardLink = nil
    }

    override func layout() {
        super.layout()
        // The shadows' cut-out spans the view: redo it after a window resize (the cards don't move: the top-left
        // stays put).
        if cardAnimation == nil { updateShadows() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    // MARK: Hit-testing

    /// Clicks go to the cards' controls through each card's page (topmost card first), never through the glass
    /// container's or glass views' own hit-testing; the clear margins and gaps belong to no view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        for card in [nowPlaying, equalizer, stations] as [GlassCard] {
            guard let parent = card.superview else { continue }
            if let hit = card.routedHit(parent.convert(local, from: self)) { return hit }
        }
        return nil
    }

    /// The shown cards' frames, in this view's coordinates.
    func shownCardFrames() -> [CGRect] {
        ModernGeometry.Card.allCases.map(card).filter { !$0.isHidden && $0.frame.height > 0 }.map(\.frame)
    }

    /// The visible card under a point in this view, if any.
    func card(at local: CGPoint) -> GlassCard? {
        for card in [nowPlaying, equalizer, stations] as [GlassCard] where !card.isHidden {
            guard let parent = card.superview, card.frame.contains(parent.convert(local, from: self)) else { continue }
            return card
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = nil
        guard onHoverOverCard != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) { hovered(event) }
    override func mouseEntered(with event: NSEvent) { hovered(event) }

    private func hovered(_ event: NSEvent) {
        guard let onHoverOverCard, let window, card(at: convert(event.locationInWindow, from: nil)) != nil else { return }
        onHoverOverCard(window.convertPoint(toScreen: event.locationInWindow))
    }

    override func rightMouseDown(with event: NSEvent) {
        onEvent?(.contextMenu(window?.convertPoint(toScreen: event.locationInWindow) ?? .zero))
    }

    override func keyDown(with event: NSEvent) {
        // Space plays or pauses (the menu bar has X, C, V, B and Z).
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onEvent?(.playPause)
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
