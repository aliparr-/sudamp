// SPDX-License-Identifier: GPL-3.0-or-later
// The content view of a skinned window (DESIGN §8.1). A layer-hosting view:
//
//   root (geometry flipped: top-left origin, like skin pixels)
//   ├─ base        SkinKit's 1x frame for the window (marquee text and visualiser left out), `.nearest`
//   ├─ patch       the part of a newer base frame that differs from the one `base` shows (the ticking time), so a
//   │              second's change uploads a few hundred pixels instead of the whole window
//   ├─ visualizer  76x16 (main) or 38x5 (shade) frame, redrawn at 30 Hz from the visualiser provider
//   ├─ marquee     154x6 marquee text over the base's pixels, redrawn when the scroll step changes
//   └─ overlay     Core Text title for characters the skin font lacks (≥ 2 device px per skin px)
//
// Every layer shows a whole-pixel 1x image stretched by an integer factor with nearest-neighbour filtering at
// whole-point frames, so the window is pixel-exact at scale 1, 2 and 3. The base recomposes only when what it
// shows changes (whole seconds, a pressed button, a moved slider, state from the app); the 30 Hz display link
// runs only while the visualiser animates and redraws only it; marquee steps (every 220 ms) and the pause blink
// (every second) are redrawn by a one-shot timer set for the moment they change, so a scrolling title or a paused
// clock costs a few redraws a second instead of thirty.
//
// Input goes through SkinInteraction (pure); its outputs reach WindowManager via `onOutput`.

import AppKit
import QuartzCore
import SkinKit

/// Window-level state owned by WindowManager and shown in the skin.
nonisolated public struct SkinChrome: Equatable, Sendable {
    /// Lights the main window's EQ / PL buttons.
    public var eqOpen = true
    public var playlistOpen = true
    /// Lights clutter-bar D.
    public var doubleSize = false
    /// region.txt shaping; off = rectangular, opaque windows (S1 kill switch).
    public var applyRegion = true

    public init() {}
}

public final class SkinView: NSView {
    public let role: SkinWindowRole
    public private(set) var kind: WindowKind
    public private(set) var scale: Int
    public private(set) var skin: Skin

    /// What to draw; set by WindowManager (or directly when used alone).
    public var playerState = SkinPlayerState() {
        didSet { playerStateChanged(from: oldValue) }
    }

    public var chrome = SkinChrome() {
        didSet { if chrome != oldValue { refresh() } }
    }

    /// Pulled at up to 30 Hz while the visualiser shows.
    public var visualizerProvider: VisualizerProvider?

    /// Interaction outputs (control events and window drags).
    public var onOutput: ((SkinInteractionOutput, SkinView) -> Void)?

    /// Skin files dropped on the window (DESIGN §8.2: load by drag-and-drop). Returns whether they were taken.
    public var onFileDrop: (([URL]) -> Bool)?

    /// Seconds on a monotonic clock; injectable for tests.
    public var clock: () -> Double = { CACurrentMediaTime() }

    /// Stop display-link frames while the window is fully occluded (DESIGN M5). Off only for measurements.
    public var pausesWhenOccluded = true {
        didSet { updateDisplayLinkDemand() }
    }

    // MARK: Layers

    let rootLayer = CALayer()
    public let baseLayer = CALayer()
    /// Shows `baseBitmap` cropped to the pixels that changed since `baseLayer`'s image (windows on screen only).
    public let patchLayer = CALayer()
    public let visualizerLayer = CALayer()
    public let marqueeLayer = CALayer()
    let overlayClip = CALayer()
    let overlayText = CATextLayer()

    // MARK: State

    public private(set) var interaction: SkinInteraction
    private var marqueeClock = MarqueeClock()
    private var pausedSince: Double?
    private var peaks = PeakTracker()
    private var playlistFirstRow = 0
    private var playlistSelected: [Int] = []
    private var focused = false
    private var skinGeneration = 0
    private var baseGeneration = 0
    private var scrollRemainder: CGFloat = 0
    /// The last base frame (SkinKit composer output) and the state it was drawn from. On screen it is `baseLayer`'s
    /// image with `patchLayer` over the pixels that changed since.
    public private(set) var baseBitmap: Bitmap?
    /// The image `baseLayer` holds, and the skin rect `patchLayer` covers.
    private var baseLayerBitmap: Bitmap?
    public private(set) var patchRect: IntRect?
    public private(set) var baseState: WindowState?
    /// Marquee layer metadata from the last redraw (font fallback, colours, offset).
    public private(set) var marqueeMetadata: RenderMetadata.Marquee?
    /// The last marquee (154x6) and visualiser layer images, as 1x bitmaps.
    public private(set) var marqueeBitmap: Bitmap?
    public private(set) var visualizerBitmap: Bitmap?
    /// Whether the visualiser / Core Text title overlay currently show.
    public var isVisualizerShown: Bool { !visualizerLayer.isHidden }
    public var isTitleOverlayShown: Bool { !overlayClip.isHidden }
    private var marqueeKey: MarqueeKey?
    /// Whether the current title scrolls (long or drawn by the Core Text overlay).
    private var marqueeMoves = false
    private var shapeKey: ShapeKey?
    private var needsShadowInvalidation = false
    private var displayLink: CADisplayLink?
    /// Fires when the marquee steps or the pause blink toggles next.
    private var stepTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    /// A drag of a window used without WindowManager: pointer and window origin at the start.
    private var standaloneDrag: (mouse: CGPoint, origin: CGPoint)?
    private lazy var accessibilityItems: [SkinAccessibilityElement] = makeAccessibilityElements()

    private struct MarqueeKey: Equatable {
        var title: String
        var step: Int
        var drag: Int
        var base: Int
        var systemFont: Bool
        var alwaysSkinFont: Bool
    }

    private struct ShapeKey: Equatable {
        var kind: WindowKind
        var scale: Int
        var skin: Int
        var region: Bool
    }

    public init(role: SkinWindowRole, skin: Skin, scale: Int, shaded: Bool = false) {
        self.role = role
        self.skin = skin
        self.scale = SkinScale.clamp(scale)
        kind = role.kind(shaded: shaded)
        interaction = SkinInteraction(role: role)
        super.init(frame: CGRect(origin: .zero, size: SkinScale.pointSize(kind, scale: self.scale)))
        // Layer-hosting: the view owns the whole tree and AppKit never draws into it.
        layer = rootLayer
        wantsLayer = true
        rootLayer.isGeometryFlipped = true
        rootLayer.masksToBounds = true
        for pixelLayer in [baseLayer, patchLayer, visualizerLayer, marqueeLayer] {
            pixelLayer.contentsGravity = .resize
            pixelLayer.magnificationFilter = .nearest
            pixelLayer.minificationFilter = .nearest
            pixelLayer.isOpaque = false
            pixelLayer.allowsEdgeAntialiasing = false
            pixelLayer.edgeAntialiasingMask = []
            rootLayer.addSublayer(pixelLayer)
        }
        overlayClip.masksToBounds = true
        overlayClip.isHidden = true
        overlayClip.addSublayer(overlayText)
        overlayText.alignmentMode = .left
        overlayText.isWrapped = false
        overlayText.truncationMode = .none
        rootLayer.addSublayer(overlayClip)
        patchLayer.isHidden = true
        for quiet in [rootLayer, baseLayer, patchLayer, visualizerLayer, marqueeLayer, overlayClip, overlayText] {
            quiet.actions = Self.noAnimations
        }
        marqueeClock.setTitle(playerState.title, now: clock())
        layoutLayers()
        refresh()
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SkinView is created in code") }

    private static let noAnimations: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "hidden": NSNull(),
        "string": NSNull(), "foregroundColor": NSNull(), "fontSize": NSNull(), "contentsScale": NSNull(),
        "sublayers": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
    ]

    override public var isFlipped: Bool { true }
    override public var isOpaque: Bool { false }
    override public var acceptsFirstResponder: Bool { true }
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Configuration

    /// Switches window kind (shade), scale or skin; resizes the view (the window follows in WindowManager).
    public func configure(kind newKind: WindowKind? = nil, scale newScale: Int? = nil, skin newSkin: Skin? = nil) {
        if let newKind { kind = newKind }
        if let newScale { scale = SkinScale.clamp(newScale) }
        if let newSkin {
            skin = newSkin
            skinGeneration += 1
        }
        setFrameSize(SkinScale.pointSize(kind, scale: scale))
        layoutLayers()
        baseState = nil
        baseLayerBitmap = nil
        marqueeKey = nil
        visualizerBitmap = nil
        _ = interaction.cancel()
        accessibilityItems = makeAccessibilityElements()
        refresh()
        visualizerStateChanged()
        updateDisplayLinkDemand()
    }

    /// The window is (or is no longer) the key window: active title bars.
    public func setFocused(_ isFocused: Bool) {
        guard focused != isFocused else { return }
        focused = isFocused
        refresh()
    }

    /// Scrolls the station list so `row` is the first visible row.
    public func scrollPlaylist(toRow row: Int) {
        playlistFirstRow = min(max(row, 0), SkinStateMapper.maxFirstRow(rowCount: playerState.playlist.count))
        refresh()
    }

    public var firstVisibleRow: Int { playlistFirstRow }
    public var selectedRows: [Int] { playlistSelected }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func layoutLayers() {
        let size = SkinScale.pointSize(kind, scale: scale)
        rootLayer.frame = CGRect(origin: .zero, size: size)
        rootLayer.bounds = CGRect(origin: .zero, size: size)
        baseLayer.frame = CGRect(origin: .zero, size: size)
        let visRect: IntRect? = switch kind {
        case .main: MainLayout.visualizer
        case .shade: ShadeLayout.visualizer
        default: nil
        }
        visualizerLayer.frame = visRect.map { SkinScale.viewRect($0, scale: scale) } ?? .zero
        if visRect == nil { visualizerLayer.isHidden = true }  // otherwise visualizerStateChanged() decides
        let marqueeRect = SkinScale.viewRect(MainLayout.marqueeText, scale: scale)
        marqueeLayer.frame = kind == .main ? marqueeRect : .zero
        marqueeLayer.isHidden = kind != .main
        overlayClip.frame = marqueeRect
        if kind != .main { overlayClip.isHidden = true }
        let contentsScale = backingScale
        if let patchRect { patchLayer.frame = SkinScale.viewRect(patchRect, scale: scale) }
        for l in [rootLayer, baseLayer, patchLayer, visualizerLayer, marqueeLayer, overlayClip, overlayText] {
            l.contentsScale = contentsScale
        }
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutLayers()
        marqueeKey = nil
        refresh()
    }

    // MARK: Composition

    /// The view-local half of the composer state.
    public func localState(now: Double) -> SkinLocalState {
        var local = SkinLocalState()
        local.focused = focused
        local.eqOpen = chrome.eqOpen
        local.playlistOpen = chrome.playlistOpen
        local.doubleSize = chrome.doubleSize
        local.applyRegion = chrome.applyRegion
        local.systemFontAvailable = SkinScale.devicePixelsPerSkinPixel(scale: scale, backingScaleFactor: backingScale) >= 2
        local.pressed = interaction.pressed
        local.marqueeStep = marqueeClock.step(at: now)
        local.marqueeDrag = interaction.marqueeDrag
        local.blinkVisible = pausedSince.map { PauseBlink.isVisible(secondsPaused: now - $0) } ?? true
        local.playlistFirstRow = playlistFirstRow
        local.playlistSelected = playlistSelected
        local.overrides = interaction.overrides
        return local
    }

    /// The full composer state for this window right now (title and marquee step included).
    public func windowState(now: Double? = nil) -> WindowState {
        SkinStateMapper.windowState(playerState, kind: kind, local: localState(now: now ?? clock()))
    }


    /// Recomposes whatever changed: the base (rarely) and the marquee layer (on scroll steps).
    public func refresh(now: Double? = nil) {
        let t = now ?? clock()
        let full = windowState(now: t)
        var base = full
        base.title = ""
        base.marqueeStep = 0
        base.marqueeDrag = 0
        if base != baseState || baseBitmap == nil {
            let result = WindowComposer.render(kind, state: base, skin: skin, hash: false)
            let previous = baseBitmap
            baseBitmap = result.bitmap
            baseState = base
            baseGeneration += 1
            let shape = ShapeKey(kind: kind, scale: scale, skin: skinGeneration, region: result.metadata.regionApplied)
            let shapeChanged = shape != shapeKey
            show(base: result.bitmap, previous: previous, reshaped: shapeChanged)
            if shapeChanged {
                shapeKey = shape
                scheduleShadowInvalidation()
            }
        }
        if kind == .main { updateMarquee(full) }
        if visualizerLayer.isHidden == visualizerShouldShow { visualizerStateChanged() }
    }

    /// Puts a new base frame on screen: as a patch over the old image when only a small area changed (the time,
    /// a pressed button) and the window is on screen, else as the base layer's whole image.
    private func show(base new: Bitmap, previous: Bitmap?, reshaped: Bool) {
        if window != nil, !reshaped, let previous, let shown = baseLayerBitmap, previous.size == new.size,
           shown.size == new.size {
            guard let changed = Self.changedRect(previous, new) else { return }
            let union = patchRect.map { Self.union($0, changed) } ?? changed
            if union.width * union.height * Self.patchAreaDivisor <= new.width * new.height {
                patchRect = union
                patchLayer.contents = new.cropped(union).cgImage()
                patchLayer.frame = SkinScale.viewRect(union, scale: scale)
                if patchLayer.isHidden { patchLayer.isHidden = false }
                return
            }
        }
        baseLayer.contents = new.cgImage()
        baseLayerBitmap = new
        patchRect = nil
        if !patchLayer.isHidden { patchLayer.isHidden = true }
    }

    /// A patch may cover at most 1/8 of the window; larger changes replace the base image.
    static let patchAreaDivisor = 8

    /// The bounding rect of the pixels that differ between two same-sized frames; nil when identical.
    nonisolated static func changedRect(_ a: Bitmap, _ b: Bitmap) -> IntRect? {
        guard a.width == b.width, a.height == b.height else { return IntRect(0, 0, b.width, b.height) }
        let rowBytes = a.width * 4
        var minX = a.width, maxX = -1, minY = a.height, maxY = -1
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                guard let ra = pa.baseAddress, let rb = pb.baseAddress else { return }
                var y = 0
                while y < a.height {
                    let offset = y * rowBytes
                    if memcmp(ra + offset, rb + offset, rowBytes) != 0 {
                        minY = min(minY, y)
                        maxY = y
                        var x = 0
                        while x < a.width {
                            let i = offset + x * 4
                            if ra[i] != rb[i] || ra[i + 1] != rb[i + 1] || ra[i + 2] != rb[i + 2] || ra[i + 3] != rb[i + 3] {
                                minX = min(minX, x)
                                maxX = max(maxX, x)
                            }
                            x += 1
                        }
                    }
                    y += 1
                }
            }
        }
        guard maxY >= 0 else { return nil }
        return IntRect(minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    nonisolated static func union(_ a: IntRect, _ b: IntRect) -> IntRect {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.x + a.width, b.x + b.width), y1 = max(a.y + a.height, b.y + b.height)
        return IntRect(x0, y0, x1 - x0, y1 - y0)
    }

    private func updateMarquee(_ state: WindowState) {
        guard let base = baseBitmap else { return }
        let mapped = SkinFontText.map(state.title)
        let moves = mapped.needsFallback || MarqueeModel.isLong(mapped.characters.count)
        if moves != marqueeMoves {
            marqueeMoves = moves
            updateDisplayLinkDemand()
        }
        let key = MarqueeKey(title: state.title, step: moves ? state.marqueeStep : 0, drag: moves ? state.marqueeDrag : 0,
                             base: baseGeneration, systemFont: state.options.systemFontAvailable,
                             alwaysSkinFont: state.options.alwaysSkinFont)
        guard key != marqueeKey else { return }
        marqueeKey = key
        let (bitmap, metadata) = WindowComposer.marqueeLayer(state: state, skin: skin, base: base)
        marqueeLayer.contents = bitmap.cgImage()
        marqueeBitmap = bitmap
        marqueeMetadata = metadata
        updateOverlay(metadata, state: state)
    }

    /// Core Text for titles the skin font cannot draw, in text.bmp's colours (DESIGN §8.3), scrolling like the
    /// marquee: 5 px per step, looping with the "  ***  " separator.
    private func updateOverlay(_ metadata: RenderMetadata.Marquee, state: WindowState) {
        guard metadata.fallback == "system" else {
            overlayClip.isHidden = true
            return
        }
        let s = CGFloat(scale)
        let font = NSFont.systemFont(ofSize: 5.5 * s)
        let width = (state.title as NSString).size(withAttributes: [.font: font]).width
        let clip = overlayClip.bounds.width
        let loopWidth = width + (MarqueeModel.separator as NSString).size(withAttributes: [.font: font]).width
        let long = width > clip
        overlayText.string = long ? state.title + MarqueeModel.separator + state.title : state.title
        overlayText.font = font
        overlayText.fontSize = font.pointSize
        overlayText.foregroundColor = Self.cgColor(hex: metadata.foreground)
        var offset: CGFloat = 0
        if long, loopWidth > 0 {
            let raw = CGFloat(state.marqueeStep * MarqueeModel.characterWidth + state.marqueeDrag) * s
            offset = raw.truncatingRemainder(dividingBy: loopWidth)
            if offset < 0 { offset += loopWidth }
        }
        let height = overlayClip.bounds.height
        let lineHeight = ceil(font.ascender - font.descender)
        overlayText.frame = CGRect(x: -offset, y: (height - lineHeight) / 2 - s * 0.5,
                                   width: (long ? width + loopWidth : width) + 2, height: lineHeight)
        overlayClip.isHidden = false
    }

    static func cgColor(hex: String) -> CGColor {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0xFFFFFF
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private var visualizerShouldShow: Bool {
        (kind == .main || kind == .shade) && playerState.playState != .stopped && playerState.visualizerMode != .off
    }

    /// Frames are pulled only while playing; paused keeps the last frame on screen.
    private var visualizerAnimates: Bool {
        visualizerShouldShow && playerState.playState == .playing
    }

    private func visualizerStateChanged() {
        guard visualizerShouldShow else {
            visualizerLayer.isHidden = true
            peaks.reset()
            return
        }
        if visualizerAnimates || visualizerBitmap == nil {
            updateVisualizer()
        } else {
            visualizerLayer.isHidden = false
        }
    }

    /// Pulls one visualiser frame and redraws its layer.
    public func updateVisualizer() {
        guard visualizerShouldShow else {
            visualizerLayer.isHidden = true
            peaks.reset()
            return
        }
        let frame = VisualizerAdapter.frame(visualizerProvider?(), mode: playerState.visualizerMode, tracker: &peaks)
        // An unchanged frame (silence, a stalled stream) costs no new image and no layer update.
        if frame == lastVisualizerFrame, visualizerBitmap != nil, !visualizerLayer.isHidden { return }
        lastVisualizerFrame = frame
        let bitmap = WindowComposer.visualizerLayer(frame, skin: skin, shade: kind == .shade)
        visualizerLayer.contents = bitmap.cgImage()
        visualizerBitmap = bitmap
        if visualizerLayer.isHidden { visualizerLayer.isHidden = false }
    }

    private var lastVisualizerFrame: VisualizerFrame?

    private func playerStateChanged(from old: SkinPlayerState) {
        guard playerState != old else { return }
        let now = clock()
        marqueeClock.setTitle(playerState.title, now: now)
        if playerState.playState == .paused {
            if old.playState != .paused || pausedSince == nil { pausedSince = now }
            // Paused means still: the title stops where it is (only the time blinks), which also keeps a paused
            // player near zero CPU.
            if marqueeClock.runningSince != nil, !interaction.isScrubbingMarquee { marqueeClock.freeze(now: now) }
        } else {
            pausedSince = nil
            if old.playState == .paused, !interaction.isScrubbingMarquee { marqueeClock.unfreeze(now: now) }
        }
        interaction.overrides.clear(keeping: interaction.activeSlider)
        playlistSelected = playlistSelected.filter { $0 < playerState.playlist.count }
        playlistFirstRow = min(playlistFirstRow, SkinStateMapper.maxFirstRow(rowCount: playerState.playlist.count))
        refresh(now: now)
        if old.playState != playerState.playState || old.visualizerMode != playerState.visualizerMode {
            visualizerStateChanged()
            updateDisplayLinkDemand()
        } else if old.title != playerState.title {
            updateStepTimer()  // the marquee restarted from the beginning
        }
    }

    /// Advances time: the visualiser, the marquee step, the pause blink, deferred shadow invalidation.
    public func tick(now: Double? = nil) {
        let t = now ?? clock()
        if needsShadowInvalidation {
            needsShadowInvalidation = false
            window?.invalidateShadow()
        }
        if visualizerAnimates { updateVisualizer() }
        refresh(now: t)
    }

    /// Display-link frames per second this view needs now: 30 while the visualiser animates, none otherwise (the
    /// marquee and the blink have their own timer; state changes redraw on their own).
    public var desiredFrameRate: Float {
        switch kind {
        case .main, .shade: visualizerAnimates ? 30 : 0
        case .playlist, .eq, .eqShade: 0
        }
    }

    /// When the marquee next steps or the paused time next blinks (monotonic seconds), if either is moving.
    public func nextTimedRedraw(after now: Double) -> Double? {
        var next: Double?
        if kind == .main, marqueeMoves, let start = marqueeClock.runningSince {
            if now < start {
                next = start
            } else {
                let steps = ((now - start) / MarqueeModel.stepInterval).rounded(.down) + 1
                next = start + steps * MarqueeModel.stepInterval
            }
        }
        if kind != .eq, kind != .eqShade, playerState.playState == .paused, let since = pausedSince {
            let toggle = since + max(2, (now - since).rounded(.down) + 1)
            next = min(next ?? toggle, toggle)
        }
        return next
    }

    private var isShowing: Bool {
        guard let window else { return false }
        return !pausesWhenOccluded || window.occlusionState.contains(.visible)
    }

    private func updateDisplayLinkDemand() {
        updateStepTimer()
        guard let displayLink, window != nil else { return }
        let rate = desiredFrameRate
        if rate > 0 { displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate) }
        displayLink.isPaused = rate == 0 || !isShowing
    }

    /// (Re)arms the one-shot timer for the next marquee step or blink toggle (none while hidden or still).
    private func updateStepTimer() {
        stepTimer?.invalidate()
        stepTimer = nil
        nextStepDue = nil
        guard displayLink != nil, isShowing else { return }
        let now = clock()
        guard let next = nextTimedRedraw(after: now) else { return }
        nextStepDue = next
        // While the display link runs for the visualiser, its frames take the steps too: one wake-up, one commit.
        if desiredFrameRate > 0 { return }
        let timer = Timer(timeInterval: max(0.001, next - now + 0.001), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepTimerFired() }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        stepTimer = timer
    }

    private func stepTimerFired() {
        stepTimer = nil
        guard let window, window.isVisible else { return }
        stepTicks += 1
        refresh()
        updateStepTimer()
    }

    /// Marquee/blink timer redraws, for logs and measurements.
    public private(set) var stepTicks = 0
    /// When the next marquee step or blink toggle is due (the timer's, or the display link's while it runs).
    private var nextStepDue: Double?

    // MARK: Shadow

    /// The window shadow follows the alpha shape (S1); recompute it once the new contents are committed: on the
    /// next display-link frame, or on the next main-actor turn when the link is paused.
    private func scheduleShadowInvalidation() {
        needsShadowInvalidation = true
        Task { @MainActor [weak self] in
            guard let self, self.needsShadowInvalidation else { return }
            self.needsShadowInvalidation = false
            self.window?.invalidateShadow()
        }
    }

    // MARK: Display link

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopDisplayLink()
        guard let window else { return }
        layoutLayers()
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        updateDisplayLinkDemand()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }
        refresh()
    }

    /// Stops the display link and the step timer for good (WindowManager calls this when tearing down).
    public func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        stepTimer?.invalidate()
        stepTimer = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }

    /// Visualiser drawing pauses while the window is fully hidden (DESIGN M5: "paused when occluded").
    private func occlusionChanged() {
        updateDisplayLinkDemand()
        if window?.occlusionState.contains(.visible) == true { tick() }
    }

    public var isDisplayLinkRunning: Bool { displayLink.map { !$0.isPaused } ?? false }

    /// Display-link callbacks that did work, for logs and measurements.
    public private(set) var displayTicks = 0

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let window, window.isVisible else { return }
        displayTicks += 1
        if needsShadowInvalidation {
            needsShadowInvalidation = false
            window.invalidateShadow()
        }
        // The visualiser, plus a marquee step or blink toggle when one is due; the base otherwise redraws only on
        // state changes.
        if visualizerAnimates { updateVisualizer() }
        if let due = nextStepDue {
            let now = clock()
            if now >= due {
                stepTicks += 1
                refresh(now: now)
                nextStepDue = nextTimedRedraw(after: now)
            }
        }
    }

    // MARK: Input

    private func pointer(_ event: NSEvent) -> SkinPointer {
        let local = convert(event.locationInWindow, from: nil)
        let screen = window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        return SkinPointer(skin: SkinScale.skinPoint(local, scale: scale), screen: screen, clickCount: event.clickCount)
    }

    override public func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        deliver(interaction.mouseDown(pointer(event), kind: kind, state: windowState()))
    }

    override public func mouseDragged(with event: NSEvent) {
        deliver(interaction.mouseDragged(pointer(event), kind: kind, state: windowState()))
    }

    override public func mouseUp(with event: NSEvent) {
        deliver(interaction.mouseUp(pointer(event), kind: kind, state: windowState()))
    }

    override public func rightMouseDown(with event: NSEvent) {
        deliver(interaction.rightMouseDown(pointer(event)))
    }

    override public func scrollWheel(with event: NSEvent) {
        // Trackpads report points; a wheel notch is one line. 10 points make one step. The list scrolls with
        // the content direction (positive = earlier rows); volume follows the physical direction (up = louder).
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        let physical = event.isDirectionInvertedFromDevice ? -delta : delta
        scrollRemainder += kind == .playlist ? delta : physical
        let steps = Int(scrollRemainder.rounded(.towardZero))
        guard steps != 0 else { return }
        scrollRemainder -= CGFloat(steps)
        deliver(interaction.scroll(steps: steps, kind: kind, state: windowState()))
    }

    /// Winamp's transport keys: Z previous, X play, C pause, V stop, B next.
    override public func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, let event = Self.keyEvent(event.charactersIgnoringModifiers ?? "") {
            deliver([.event(event)])
        } else {
            super.keyDown(with: event)
        }
    }

    nonisolated static func keyEvent(_ characters: String) -> SkinControlEvent? {
        switch characters.lowercased() {
        case "z": return .previous
        case "x": return .play
        case "c": return .pause
        case "v": return .stop
        case "b": return .next
        default: return nil
        }
    }

    /// Hands outputs on, after applying the view-local effects (row selection, scroll, marquee clock).
    func deliver(_ outputs: [SkinInteractionOutput]) {
        guard !outputs.isEmpty else {
            refresh()
            return
        }
        let now = clock()
        var openedMenu = false
        for output in outputs {
            switch output {
            case .marqueeScrubBegan: marqueeClock.freeze(now: now)
            case .marqueeScrubEnded:
                if playerState.playState != .paused { marqueeClock.resume(now: now) }
                updateStepTimer()
            case .event(let event):
                applyLocal(event)
                if event.opensMenu {
                    // Show the pressed sprite before a menu takes over the event loop.
                    refresh(now: now)
                    CATransaction.flush()
                    openedMenu = true
                }
            default: break
            }
            if let onOutput {
                onOutput(output, self)
            } else {
                dragStandalone(output)
            }
        }
        if openedMenu {
            // A pop-up menu swallows the mouse-up; end the gesture ourselves.
            for output in interaction.cancel() { onOutput?(output, self) }
        }
        refresh()
    }

    /// Without a WindowManager the window still drags itself (no docking or snapping).
    private func dragStandalone(_ output: SkinInteractionOutput) {
        guard let window else { return }
        switch output {
        case .beginWindowDrag(let screen):
            standaloneDrag = (screen, window.frame.origin)
        case .dragWindow(let screen):
            guard let start = standaloneDrag else { return }
            window.setFrameOrigin(CGPoint(x: (start.origin.x + screen.x - start.mouse.x).rounded(),
                                          y: (start.origin.y + screen.y - start.mouse.y).rounded()))
        case .endWindowDrag:
            standaloneDrag = nil
        default:
            break
        }
    }

    private func applyLocal(_ event: SkinControlEvent) {
        switch event {
        case .playlistRowSelected(let index), .playlistRowActivated(let index):
            playlistSelected = [index]
        case .playlistScroll(let first):
            playlistFirstRow = first
            if interaction.activeSlider != .playlistScrollbar { interaction.overrides.scroll = nil }
        default:
            break
        }
    }

    // MARK: Drag and drop (skin files)

    /// File extensions a dropped skin may have (Winamp skins are ZIP archives named `.wsz`).
    nonisolated public static let skinFileExtensions: Set<String> = ["wsz", "zip"]

    nonisolated public static func isSkinFile(_ url: URL) -> Bool {
        url.isFileURL && skinFileExtensions.contains(url.pathExtension.lowercased())
    }

    private func droppedSkinFiles(_ sender: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter(Self.isSkinFile)
    }

    override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onFileDrop != nil && !droppedSkinFiles(sender).isEmpty ? .copy : []
    }

    override public func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let files = droppedSkinFiles(sender)
        guard !files.isEmpty, let onFileDrop else { return false }
        return onFileDrop(files)
    }

    // MARK: Programmatic input (agent automation; the same paths a click or drag takes)

    /// Presses a hotspot as a click would (buttons act, menu buttons open their menu, the marquee clicks).
    @discardableResult
    public func press(_ control: Control) -> Bool { accessibilityActivate(control) }

    /// Drags a slider's thumb to `fraction` of its travel (0 = left/top) through the pointer state machine: press on
    /// the thumb, one drag, release. Volume, balance, EQ and the scrollbar send values while dragging; the position
    /// slider seeks on release. False when `control` is not a slider in this window or is inert (live position).
    @discardableResult
    public func dragSlider(_ control: Control, toFraction fraction: Double) -> Bool {
        guard let track = SliderTrack.track(for: control, in: kind), let rect = Layout.rect(of: control, in: kind),
              fraction.isFinite else { return false }
        let state = windowState()
        guard case .slider = SkinInteraction.behaviour(of: control, in: kind, state: state) else { return false }
        let half = track.thumbLength / 2
        let from = track.leading(fraction: interaction.currentFraction(control, state: state)) + half
        let to = track.leading(fraction: min(max(fraction, 0), 1)) + half
        func sample(_ along: Double) -> SkinPointer {
            let skin = track.axis == .horizontal
                ? CGPoint(x: along, y: Double(rect.y) + Double(rect.height) / 2)
                : CGPoint(x: Double(rect.x) + Double(rect.width) / 2, y: along)
            let screen = screenRect(forSkinRect: IntRect(Int(skin.x.rounded(.down)), Int(skin.y.rounded(.down)), 1, 1))
            return SkinPointer(skin: skin, screen: CGPoint(x: screen.midX, y: screen.midY))
        }
        deliver(interaction.mouseDown(sample(from), kind: kind, state: state))
        deliver(interaction.mouseDragged(sample(to), kind: kind, state: windowState()))
        deliver(interaction.mouseUp(sample(to), kind: kind, state: windowState()))
        return true
    }

    // MARK: Accessibility

    override public func isAccessibilityElement() -> Bool { false }
    override public func accessibilityRole() -> NSAccessibility.Role? { .group }
    override public func accessibilityLabel() -> String? { role.title }
    override public func accessibilityChildren() -> [Any]? { accessibilityItems }

    /// Every hotspot of the current window kind as an accessibility element.
    public var accessibilityElementsForTesting: [SkinAccessibilityElement] { accessibilityItems }

    private func makeAccessibilityElements() -> [SkinAccessibilityElement] {
        Layout.hitRects(kind).compactMap { control, rect in
            control == .titleBar ? nil : SkinAccessibilityElement(
                control: control, rect: rect, view: self, identifier: "skin.\(role.rawValue).\(control.rawValue)")
        }
    }

    /// The screen rect of a skin rect, for accessibility frames and menu anchors.
    public func screenRect(forSkinRect rect: IntRect) -> CGRect {
        let local = SkinScale.viewRect(rect, scale: scale)
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }

    /// Performs a hotspot's action as if clicked (VoiceOver "press").
    func accessibilityActivate(_ control: Control) -> Bool {
        let state = windowState()
        let rect = Layout.rect(of: control, in: kind) ?? IntRect(0, 0, 1, 1)
        let screen = screenRect(forSkinRect: rect)
        let point = CGPoint(x: screen.midX, y: screen.midY)
        switch SkinInteraction.behaviour(of: control, in: kind, state: state) {
        case .button:
            guard let event = SkinInteraction.buttonEvent(control, role: role, kind: kind, state: state, screen: point)
            else { return false }
            deliver([.event(event)])
        case .menu:
            guard let event = SkinInteraction.menuEvent(control, screen: point) else { return false }
            deliver([.event(event)])
        case .marquee:
            deliver([.event(.marqueeClick(screenPoint: point))])
        case .rows:
            guard let first = playlistSelected.first ?? playerState.currentRow else { return false }
            deliver([.event(.playlistRowActivated(index: first))])
        default:
            return false
        }
        return true
    }

    /// Moves a slider by `steps` increments (VoiceOver increment/decrement).
    func accessibilityAdjust(_ control: Control, steps: Int) -> Bool {
        let state = windowState()
        let event: SkinControlEvent?
        switch control {
        case .volume:
            event = .volume(min(max(Double(state.volume) / 100 + 0.05 * Double(steps), 0), 1))
        case .balance:
            event = .balance(min(max(Double(state.balance) / 100 + 0.25 * Double(steps), -1), 1))
        case .position:
            guard let p = state.effectivePosition, state.duration != nil else { return false }
            event = .seek(fraction: min(max(p + 0.05 * Double(steps), 0), 1))
        case .preamp:
            event = .preamp(decibels: min(max(playerState.equalizer.preamp + Double(steps), -12), 12))
        case .playlistScrollbar:
            let maxFirst = SkinStateMapper.maxFirstRow(rowCount: state.playlist.rows.count)
            event = .playlistScroll(firstRow: min(max(state.playlist.firstRow - steps, 0), maxFirst))
        default:
            guard let index = Control.bands.firstIndex(of: control) else { return false }
            let current = index < playerState.equalizer.bands.count ? playerState.equalizer.bands[index] : 0
            event = .eqBand(index: index, decibels: min(max(current + Double(steps), -12), 12))
        }
        guard let event else { return false }
        deliver([.event(event)])
        return true
    }

    /// The accessibility value of a hotspot (slider position, toggle state, title).
    func accessibilityValue(for control: Control) -> SkinAccessibilityElement.Value? {
        let state = windowState()
        func flag(_ on: Bool) -> SkinAccessibilityElement.Value { .number(on ? 1 : 0) }
        switch control {
        case .volume: return .number(Double(state.volume) / 100)
        case .balance: return .number(Double(state.balance) / 100)
        case .position: return .number(state.effectivePosition ?? 0)
        case .preamp: return .number(playerState.equalizer.preamp)
        case .shuffle: return flag(playerState.shuffle)
        case .repeat: return flag(playerState.repeat)
        case .eqOn: return flag(playerState.equalizer.enabled)
        case .eqAuto: return flag(playerState.equalizer.auto)
        case .eqToggle: return flag(chrome.eqOpen)
        case .playlistToggle: return flag(chrome.playlistOpen)
        case .clutterD: return flag(chrome.doubleSize)
        case .marquee: return .text(playerState.title)
        case .time, .playlistMiniTime:
            let remaining = playerState.timeDisplay == .remaining ? playerState.remaining : nil
            return .text((remaining != nil ? "-" : "") + SkinStateMapper.clock(remaining ?? playerState.elapsed))
        case .playlistScrollbar: return .number(state.playlist.scroll)
        case .playlistList: return .text("\(playerState.playlist.count) stations")
        default:
            if let index = Control.bands.firstIndex(of: control), index < playerState.equalizer.bands.count {
                return .number(playerState.equalizer.bands[index])
            }
            return nil
        }
    }
}
