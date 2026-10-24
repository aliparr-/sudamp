// SPDX-License-Identifier: GPL-3.0-or-later
// The generated artwork: streams carry no cover art, so every genre gets its own living picture. A diagonal base
// gradient in the genre's colours (the tint's when no genre is picked), three soft blobs of light that drift slowly
// and swell with the bass, a little film grain, a gloss across the top and a hairline rim, with a coloured glow
// underneath.
// The visualiser is drawn into it: one of the scenes (`Visualizer/`), each frame a bitmap from `SceneRenderer`, with
// the palette's glow around it, and the effect (VHS, Kaleidoscope) over it. Frames come 30 times a second while
// playing. With Rotate, the scenes take turns, cross-fading: a breakdown brings a calm scene and the drop a lively
// one, and a new genre opens on a scene that suits it. With the Cycle colours, the artwork's hue turns as the music
// plays. Stopped or paused, the scene settles to a still frame and nothing animates.

import AppKit
import QuartzCore

final class ArtworkView: NSView {
    typealias Mode = ModernPlayerState.Visualizer

    /// What the artwork's colours are made from (with `.cycle`, the hue also turns while playing).
    var paletteKey = ArtworkPalette.Key() {
        didSet {
            if paletteKey.genreKey != oldValue.genreKey { genreChanged() }
            if paletteKey != oldValue { paletteChanged() }
        }
    }
    private(set) var palette = ArtworkPalette.make(ArtworkPalette.Key())
    var mode: Mode = .default {
        didSet { if mode != oldValue { modeChanged() } }
    }
    /// Seconds per scene while rotating.
    var rotationInterval = ModernPlayerState.defaultVisualizerInterval {
        didSet { rotation.interval = rotationInterval }
    }
    /// The finish over the scene.
    var effect = ModernPlayerState.VisualizerEffect.none {
        didSet {
            guard effect != oldValue else { return }
            renderer.effect = effect
            needsStill = true
            if !isAnimating { drawStillIfNeeded() }
        }
    }
    /// What is playing, for a scene that writes it out (`Title · Creator`).
    var caption = "" {
        didSet { features.caption = caption }
    }
    /// Playing: the light drifts and the visualiser moves.
    var isAnimating = false {
        didSet { if isAnimating != oldValue { animatingChanged() } }
    }
    var cornerRadius: CGFloat = 16 { didSet { needsLayout = true } }
    var onClick: (() -> Void)?

    private let glowLayer = StillShapeLayer()
    private let clip = StillLayer()
    private let base = StillGradientLayer()
    private var blobs: [StillGradientLayer] = []
    private let blobHolder = StillLayer()
    private let grain = StillLayer()
    private let shade = StillGradientLayer()
    /// The visualiser's frames.
    let sceneLayer = StillLayer()
    private let gloss = StillGradientLayer()
    private let rim = StillLayer()
    private let renderer = SceneRenderer()
    private var features = AudioFeatures()
    private var rotation = VisualizerRotation(interval: ModernPlayerState.defaultVisualizerInterval)
    private var lastTick: CFTimeInterval?
    /// How far the Cycle colours have turned (0...1, wrapping), and where the palette last changed.
    private var cycle: Double = 0
    private var appliedCycle: Double = 0
    private var bassLevel: Float = 0
    /// A still frame is due (stopped or paused, after a change).
    private var needsStill = true
    /// The scene the last still frame settled (a new one gets a moment of silence first).
    private var settledScene: Mode?

    /// The scene showing (while rotating, the current one).
    var currentScene: Mode? { mode == .off ? nil : renderer.mode }
    /// Frames drawn since the view was made (tests).
    private(set) var framesDrawn = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        glowLayer.fillColor = CGColor(gray: 0, alpha: 1)
        layer?.addSublayer(glowLayer)
        clip.masksToBounds = true
        clip.cornerCurve = .continuous
        layer?.addSublayer(clip)
        base.startPoint = CGPoint(x: 0, y: 0)
        base.endPoint = CGPoint(x: 1, y: 1)
        clip.addSublayer(base)
        clip.addSublayer(blobHolder)
        for i in 0..<3 {
            let blob = StillGradientLayer()
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            // The highlight adds light (screen); the colour blobs lay colour down.
            if i == 0 { blob.compositingFilter = "screenBlendMode" }
            blobHolder.addSublayer(blob)
            blobs.append(blob)
        }
        grain.contents = grainImage
        grain.contentsGravity = .resize
        grain.magnificationFilter = .nearest
        grain.opacity = 0.05
        grain.compositingFilter = "softLightBlendMode"
        clip.addSublayer(grain)
        shade.startPoint = CGPoint(x: 0.5, y: 0)
        shade.endPoint = CGPoint(x: 0.5, y: 1)
        shade.locations = [0.45, 1]
        clip.addSublayer(shade)
        sceneLayer.contentsGravity = .resize
        sceneLayer.shadowOffset = .zero
        sceneLayer.shadowRadius = 3.5
        clip.addSublayer(sceneLayer)
        gloss.startPoint = CGPoint(x: 0.5, y: 0)
        gloss.endPoint = CGPoint(x: 0.5, y: 0.55)
        gloss.colors = [CGColor(gray: 1, alpha: 0.26), CGColor(gray: 1, alpha: 0)]
        clip.addSublayer(gloss)
        rim.borderWidth = 1
        rim.borderColor = CGColor(gray: 1, alpha: 0.18)
        rim.cornerCurve = .continuous
        layer?.addSublayer(rim)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Shows the next visualizer scene")
        applyPalette()
        modeChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { onClick == nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Claimed, so the mouse-up comes here (passed up, the card would start a window drag and take it).
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }

    override func layout() {
        super.layout()
        let r = bounds
        clip.frame = r
        clip.cornerRadius = cornerRadius
        rim.frame = r
        rim.cornerRadius = cornerRadius
        glowLayer.path = roundedPath(r.insetBy(dx: 6, dy: 8).offsetBy(dx: 0, dy: 6), radius: cornerRadius)
        glowLayer.shadowPath = glowLayer.path
        base.frame = r
        blobHolder.frame = r
        let blobSize = r.width * 1.3
        let anchors = [CGPoint(x: 0.18, y: 0.15), CGPoint(x: 0.92, y: 0.42), CGPoint(x: 0.35, y: 0.98)]
        for (blob, anchor) in zip(blobs, anchors) {
            blob.bounds = CGRect(x: 0, y: 0, width: blobSize, height: blobSize)
            blob.position = CGPoint(x: r.width * anchor.x, y: r.height * anchor.y)
        }
        grain.frame = r
        shade.frame = r
        gloss.frame = r
        if sceneLayer.frame != r {
            sceneLayer.frame = r
            needsStill = true
        }
        if isAnimating { startDrift() } else { drawStillIfNeeded() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sceneLayer.contentsScale = backingScale
        needsStill = true
        if !isAnimating { drawStillIfNeeded() }
    }

    // MARK: Colours

    /// A new genre: Rotate opens on a scene that suits it (unless one showing does already).
    private func genreChanged() {
        rotation.genre = paletteKey.genreKey
        guard mode == .rotate, renderer.mode != nil,
              let opening = VisualizerRotation.opening(forGenre: paletteKey.genreKey, showing: renderer.mode) else { return }
        rotation.restart()
        renderer.show(opening, animated: isAnimating && framesDrawn > 0 && !Motion.reduced)
        setAccessibilityLabel("Artwork and visualizer: \(currentScene?.title ?? mode.title)")
        needsStill = true
    }

    private func paletteChanged() {
        // A new genre, source, tint or light/dark: the cycle starts again from the tint's hue.
        if paletteKey.colors != .cycle { cycle = 0 }
        applyPalette()
    }

    private func applyPalette() {
        palette = ArtworkPalette.make(paletteKey, cycle: cycle)
        appliedCycle = cycle
        base.colors = [palette.base.0.cgColor, palette.base.1.cgColor]
        for (i, (blob, color)) in zip(blobs, palette.blobs).enumerated() {
            let alpha = i == 0 ? 0.7 : 0.62
            blob.colors = [color.cgColor(alpha: alpha), color.cgColor(alpha: alpha * 0.45), color.cgColor(alpha: 0)]
            blob.locations = [0, 0.4, 1]
        }
        shade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: palette.isLight ? 0.06 : 0.32)]
        rim.borderColor = CGColor(gray: palette.isLight ? 0 : 1, alpha: palette.isLight ? 0.08 : 0.18)
        glowLayer.shadowColor = palette.blobs.first?.mixed(with: palette.base.1, 0.3).cgColor
        glowLayer.shadowRadius = 14
        glowLayer.shadowOffset = CGSize(width: 0, height: 8)
        glowLayer.shadowOpacity = restingGlow
        sceneLayer.shadowColor = palette.glow.cgColor
        renderer.style = SceneStyle(palette)
        needsStill = true
        if !isAnimating { drawStillIfNeeded() }
    }

    private var restingGlow: Float { paletteKey.dark ? 0.55 : 0.4 }

    // MARK: Mode

    private func modeChanged() {
        switch mode {
        case .off:
            break
        case .rotate:
            rotation.restart()
            // Open on a scene that suits the genre, unless the one showing does.
            if let opening = VisualizerRotation.opening(forGenre: paletteKey.genreKey, showing: renderer.mode) {
                renderer.show(opening, animated: isAnimating && framesDrawn > 0 && !Motion.reduced)
            }
        default:
            renderer.show(mode, animated: isAnimating && framesDrawn > 0 && !Motion.reduced)
        }
        let showing = mode != .off
        if showing == sceneLayer.isHidden {
            sceneLayer.isHidden = !showing
            if showing, !Motion.reduced {
                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = 0
                fadeIn.toValue = 1
                fadeIn.duration = 0.25
                sceneLayer.add(fadeIn, forKey: "opacity")
            }
        }
        setAccessibilityLabel(mode == .off ? "Artwork" : "Artwork and visualizer: \(currentScene?.title ?? mode.title)")
        needsStill = true
        if !isAnimating { drawStillIfNeeded() }
    }

    /// While rotating: the next scene now (a click on the artwork), and its full turn.
    func skipScene() {
        guard mode == .rotate else { return }
        rotation.restart()
        renderer.show(VisualizerRotation.next(after: renderer.mode), animated: !Motion.reduced)
        setAccessibilityLabel("Artwork and visualizer: \(currentScene?.title ?? mode.title)")
        needsStill = true
        if !isAnimating { drawStillIfNeeded() }
    }

    // MARK: Motion

    private func animatingChanged() {
        if isAnimating {
            lastTick = nil
            startDrift()
        } else {
            stopDrift()
            update(with: nil)
        }
    }

    /// Slow, render-server-driven drift: each blob wanders on its own long loop.
    private func startDrift() {
        guard !Motion.reduced else { return }
        let r = bounds
        guard r.width > 0 else { return }
        for (i, blob) in blobs.enumerated() where blob.animation(forKey: "drift") == nil {
            let drift = CAKeyframeAnimation(keyPath: "position")
            let p = blob.position
            let a = r.width * 0.16
            let phase = Double(i) * 2.1
            drift.setKeyframes(objects: (0...6).map { k -> NSValue in
                let t = Double(k) / 6 * 2 * .pi + phase
                return NSValue(point: CGPoint(x: p.x + a * CGFloat(cos(t)), y: p.y + a * 0.8 * CGFloat(sin(t * 1.3))))
            })
            drift.calculationMode = .cubic
            drift.duration = 15 + Double(i) * 4.5
            drift.repeatCount = .infinity
            drift.isRemovedOnCompletion = false
            blob.add(drift, forKey: "drift")
        }
    }

    /// The light glides back to rest (the drift never moves the model position).
    private func stopDrift() {
        for blob in blobs {
            let presented = blob.presentation()?.position
            blob.removeAnimation(forKey: "drift")
            guard let presented, !Motion.reduced else { continue }
            let settle = CABasicAnimation(keyPath: "position")
            settle.fromValue = NSValue(point: presented)
            settle.toValue = NSValue(point: blob.position)
            settle.duration = 1.2
            settle.timingFunction = Motion.easeInOut
            blob.add(settle, forKey: "settle")
        }
    }

    /// One visualiser frame, called 30 times a second while animating. nil is silence after playing: the scene
    /// settles to a still frame and no frames follow.
    func update(with frame: ModernVisualizerFrame?) {
        guard let frame else { return settle() }
        let now = CACurrentMediaTime()
        let dt = lastTick.map { min(max(now - $0, 1.0 / 240), 0.1) } ?? 1.0 / 60
        lastTick = now
        step(frame, dt: dt)
    }

    /// Moves everything on by `dt` seconds of music and draws (tests drive this directly).
    func step(_ frame: ModernVisualizerFrame?, dt: Double) {
        let input = features.next(frame, dt: dt)
        if mode == .rotate, let next = rotation.advance(dt, input: input, showing: renderer.mode) {
            renderer.show(next, animated: !Motion.reduced)
            setAccessibilityLabel("Artwork and visualizer: \(currentScene?.title ?? mode.title)")
        }
        if paletteKey.colors == .cycle {
            cycle = (cycle + dt / ArtworkColors.cyclePeriod).truncatingRemainder(dividingBy: 1)
            if abs(cycle - appliedCycle) >= 1.0 / 720 { applyPalette() }
        }
        if mode != .off {
            renderer.update(input, dt: dt)
            drawScene()
        }
        // The light swells with the bass, scaled about the artwork's centre.
        bassLevel += (input.bass - bassLevel) * Float(1 - pow(0.6, dt * 30))
        blobHolder.sublayerTransform = Motion.reduced ? CATransform3DIdentity
            : Motion.scale(1 + CGFloat(bassLevel) * 0.16, around: blobHolder.bounds)
        // Shadows are costly to redraw: follow the bass only in visible steps.
        let glow = (paletteKey.dark ? 0.5 : 0.36) + bassLevel * 0.3
        if abs(glow - glowLayer.shadowOpacity) > 0.04 { glowLayer.shadowOpacity = glow }
    }

    private func drawScene() {
        guard bounds.width > 0 else { return }
        sceneLayer.contentsScale = backingScale
        sceneLayer.contents = renderer.image(size: bounds.size, scale: backingScale)
        let glow = Float(renderer.glow) * (palette.isLight ? 0.35 : 0.55)
        if abs(glow - sceneLayer.shadowOpacity) > 0.01 { sceneLayer.shadowOpacity = glow }
        framesDrawn += 1
        needsStill = false
    }

    /// Stopped: the scene calms down (a moment of silence), then holds still; the light comes to rest.
    private func settle() {
        lastTick = nil
        bassLevel = 0
        blobHolder.sublayerTransform = CATransform3DIdentity
        glowLayer.shadowOpacity = restingGlow
        guard mode != .off else { return }
        for _ in 0..<40 { renderer.update(features.next(nil, dt: 1.0 / 60), dt: 1.0 / 60) }
        settledScene = renderer.mode
        if !Motion.reduced, framesDrawn > 0 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.3
            sceneLayer.add(fade, forKey: "settle")
        }
        drawScene()
    }

    /// A still frame of the scene (stopped or paused, after a change of scene, palette or size).
    private func drawStillIfNeeded() {
        guard needsStill, !isAnimating, mode != .off, bounds.width > 0 else { return }
        // A scene new since the last still frame (or still fading in) settles in a second of silence first.
        if renderer.isFading || renderer.mode != settledScene {
            for _ in 0..<60 { renderer.update(features.next(nil, dt: 1.0 / 60), dt: 1.0 / 60) }
            settledScene = renderer.mode
        }
        drawScene()
    }

    /// Reduce Motion changed: drift starts or stops to match.
    func refreshMotion() {
        stopDrift()
        if isAnimating { startDrift() }
    }
}
