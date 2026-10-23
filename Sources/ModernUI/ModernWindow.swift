// SPDX-License-Identifier: GPL-3.0-or-later
// The modern window: borderless and clear, so all you see is the glass cards and their shadows. Clicks on the clear
// margins reach whatever is underneath (WindowServer routes clicks on transparent pixels, spike S1). Drag it by any
// part of a card that isn't a control. The cards sit in one NSGlassEffectContainerView, so when a panel slides out
// from under the player the glass flows apart like liquid.

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

/// The cards' frames for a set of open panels, pure and unit-tested. Root-view coordinates (flipped), margin
/// included: the player on top, then the Equalizer, then the stations.
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
        var out: [Card: CGRect] = [:]
        var y = Metrics.margin
        for card in Card.allCases {
            if let panel = panel(card), !open.contains(panel) { continue }
            out[card] = CGRect(x: Metrics.margin, y: y, width: Metrics.cardWidth, height: height(card))
            y += height(card) + Metrics.gap
        }
        return out
    }

    /// How much of a closed panel is left: a strip hidden inside the bottom of the card above it.
    static let tuckedHeight: CGFloat = 24

    /// Where a closed panel waits, for the cards shown in `open`: a strip inside the bottom of the card above, so its
    /// glass is part of that card's shape (glass in one container merges) and it can grow out of it like liquid.
    public static func tuckedFrame(_ card: Card, open: Set<ModernPanel>) -> CGRect {
        var without = open
        if let panel = panel(card) { without.remove(panel) }
        let shown = frames(open: without)
        let above = Card.allCases.prefix { $0 != card }.reversed().compactMap { shown[$0] }.first
        let bottom = above?.maxY ?? Metrics.margin + tuckedHeight
        return CGRect(x: Metrics.margin, y: bottom - tuckedHeight - 2, width: Metrics.cardWidth, height: tuckedHeight)
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

/// The panels' motion: a slightly underdamped spring (a touch of overshoot, settled in about half a second), pure
/// and unit-tested.
nonisolated enum CardSpring {
    static let duration = 0.6
    static let dampingRatio = 0.78
    static let frequency = 13.0

    /// Progress 0...1 of the move at `t` (0...1 of `duration`); may overshoot 1 a little, and is exactly 1 at the end.
    static func position(_ t: Double) -> Double {
        guard t < 1 else { return 1 }
        let time = max(t, 0) * duration
        let z = dampingRatio, w = frequency
        let wd = w * (1 - z * z).squareRoot()
        let decay = exp(-z * w * time)
        let value = 1 - decay * (cos(wd * time) + (z * w / wd) * sin(wd * time))
        // Fade the residual wobble out so the last frame lands exactly.
        let settle = max(0, (t - 0.85) / 0.15)
        return value + (1 - value) * settle
    }

    /// A page's opacity at `t`: appearing, it waits for the glass to clear the card above, then fades in; leaving,
    /// it fades out before the glass has gone far.
    static func fade(_ t: Double, from a: CGFloat, to b: CGFloat) -> CGFloat {
        guard a != b else { return b }
        let p = b > a ? min(max((t - 0.12) / 0.45, 0), 1) : min(max(t / 0.3, 0), 1)
        let eased = p * p * (3 - 2 * p)
        return a + (b - a) * CGFloat(eased)
    }

    static func interpolate(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        let p = CGFloat(p)
        return CGRect(x: a.minX + (b.minX - a.minX) * p, y: a.minY + (b.minY - a.minY) * p,
                      width: a.width + (b.width - a.width) * p, height: a.height + (b.height - a.height) * p)
    }
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
    private var palette: ModernPalette?
    var onEvent: ((ModernEvent) -> Void)?
    /// Called when the panels need a different window size: before an opening animation, after a closing one.
    var onResize: ((CGSize) -> Void)?
    /// Light or dark changed (the system's, or the window's own).
    var onAppearanceChange: (() -> Void)?

    /// Files dropped on the window (classic skins: the app switches to them). Returns whether they were taken.
    var onFilesDropped: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        if GlassCard.systemGlassAvailable, #available(macOS 26.0, *) {
            let glassContainer = NSGlassEffectContainerView(frame: frameRect)
            // Cards closer than this flow into each other: only while a panel slides out or back.
            glassContainer.spacing = 10
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
        layoutCards(animated: false)
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

    /// Opens and closes panels. Growing, the window grows first and the cards then slide out; shrinking, the cards
    /// slide back and the window shrinks after.
    func setPanels(_ open: Set<ModernPanel>, animated: Bool) {
        guard open != openPanels else { return }
        let old = openPanels
        openPanels = open
        nowPlaying.setPanelOpen(.equalizer, open.contains(.equalizer))
        nowPlaying.setPanelOpen(.stations, open.contains(.stations))
        let newSize = ModernGeometry.windowSize(open: open)
        let oldSize = ModernGeometry.windowSize(open: old)
        if newSize.height >= oldSize.height { onResize?(newSize) }
        layoutCards(animated: animated && window?.isVisible == true, from: old) { [weak self] in
            guard let self, self.openPanels == open else { return }
            if newSize.height < oldSize.height { self.onResize?(newSize) }
            for card in ModernGeometry.Card.allCases {
                if let panel = ModernGeometry.panel(card), !open.contains(panel) { self.card(card).isHidden = true }
            }
        }
    }

    private func layoutCards(animated: Bool, from old: Set<ModernPanel>? = nil, completion: (@MainActor () -> Void)? = nil) {
        let frames = ModernGeometry.frames(open: openPanels)
        let duration = animated ? (Motion.reduced ? 0.25 : CardSpring.duration) : 0
        var moves: [(GlassCard, CGRect, CGFloat, ModernGeometry.Card)] = []
        for kind in ModernGeometry.Card.allCases {
            let card = self.card(kind)
            if let frame = frames[kind] {
                if card.isHidden {
                    // Start as a strip inside the card above, its page clear.
                    card.frame = Motion.reduced ? frame : ModernGeometry.tuckedFrame(kind, open: openPanels)
                    card.content.alphaValue = 0
                    card.isHidden = false
                    card.layoutSubtreeIfNeeded()
                }
                moves.append((card, frame, 1, kind))
            } else if !card.isHidden {
                moves.append((card, Motion.reduced ? card.frame : ModernGeometry.tuckedFrame(kind, open: openPanels), 0, kind))
            }
        }
        guard duration > 0 else {
            cardAnimation = nil
            for (card, frame, alpha, _) in moves {
                card.frame = frame
                card.content.alphaValue = alpha
                shadows.setShadow(for: card, frame: frame, opacity: Float(alpha), animation: nil, duration: 0)
            }
            completion?()
            return
        }
        // Liquid Glass is drawn from each view's real frame, not from Core Animation's in-flight values, so the
        // cards' frames are stepped on every display frame (positions and opacity only: nothing relayouts).
        cardAnimation = CardAnimation(
            tracks: moves.map { card, frame, alpha, _ in
                .init(card: card, fromFrame: card.frame, toFrame: frame, fromAlpha: card.content.alphaValue, toAlpha: alpha)
            },
            start: CACurrentMediaTime(), duration: duration, completion: completion)
        startCardLink()
    }

    // MARK: Card animation

    private struct CardAnimation {
        struct Track {
            let card: GlassCard
            let fromFrame: CGRect
            let toFrame: CGRect
            let fromAlpha: CGFloat
            let toAlpha: CGFloat
        }
        var tracks: [Track]
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

    private func stepCards(at now: CFTimeInterval) {
        guard let animation = cardAnimation else {
            cardLink?.isPaused = true
            return
        }
        let t = min(max((now - animation.start) / animation.duration, 0), 1)
        let move = Motion.reduced ? 1 : CardSpring.position(t)
        for track in animation.tracks {
            let f = CardSpring.interpolate(track.fromFrame, track.toFrame, move)
            if f.size != track.card.frame.size {
                track.card.frame = f
            } else {
                track.card.setFrameOrigin(f.origin)
            }
            let alpha = CardSpring.fade(t, from: track.fromAlpha, to: track.toAlpha)
            track.card.content.alphaValue = alpha
            shadows.setShadow(for: track.card, frame: f, opacity: Float(alpha), animation: nil, duration: 0)
        }
        guard t >= 1 else { return }
        for track in animation.tracks {
            track.card.frame = track.toFrame
            track.card.content.alphaValue = track.toAlpha
            shadows.setShadow(for: track.card, frame: track.toFrame, opacity: Float(track.toAlpha), animation: nil, duration: 0)
        }
        cardAnimation = nil
        cardLink?.isPaused = true
        animation.completion?()
    }

    /// Whether a panel is sliding (tests, automation).
    var isAnimatingCards: Bool { cardAnimation != nil }

    /// Final: the display link holds this view, so it must be invalidated when the window goes.
    func stopAnimations() {
        if let animation = cardAnimation {
            for track in animation.tracks {
                track.card.frame = track.toFrame
                track.card.content.alphaValue = track.toAlpha
            }
            cardAnimation = nil
        }
        cardLink?.invalidate()
        cardLink = nil
    }

    override func layout() {
        super.layout()
        // Keep shadows in place after a window resize (cards don't move: the top-left stays put).
        for kind in ModernGeometry.Card.allCases {
            let card = self.card(kind)
            guard !card.isHidden, cardAnimation == nil else { continue }
            shadows.setShadow(for: card, frame: card.frame, opacity: Float(card.content.alphaValue), animation: nil, duration: 0)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
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
