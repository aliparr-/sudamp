// SPDX-License-Identifier: GPL-3.0-or-later
// The generated artwork: streams carry no cover art, so every genre gets its own living picture. A diagonal base
// gradient in the genre's colours (the tint's when no genre is picked), three soft blobs of light that drift slowly
// and swell with the bass, a little film grain, a gloss across the top and a hairline rim, with a coloured glow
// underneath.
// The visualiser is drawn into it: 19 rounded bars (the spectrum) or a smooth trace (the oscilloscope), in white
// with a soft glow. Frames arrive at 30 Hz; each one animates over 1/30 s, so the render server interpolates the
// motion at the display's own refresh rate. Nothing animates while paused or stopped.

import AppKit
import QuartzCore

/// The visualiser's shapes, pure and unit-tested.
nonisolated enum VisualizerGeometry {
    /// Rounded bars along the bottom of `rect`, one per level (0...1), never shorter than a dot.
    static func barsPath(levels: [Float], in rect: CGRect, gap: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = max(levels.count, 1)
        let width = max(1, (rect.width - gap * CGFloat(n - 1)) / CGFloat(n))
        for (i, level) in levels.enumerated() {
            let l = CGFloat(min(max(level.isFinite ? level : 0, 0), 1))
            let h = max(width, rect.height * l)
            let x = rect.minX + CGFloat(i) * (width + gap)
            // Flipped: bars stand on the bottom edge.
            let bar = CGRect(x: x, y: rect.maxY - h, width: width, height: h)
            path.addRoundedRect(in: bar, cornerWidth: width / 2, cornerHeight: width / 2)
        }
        return path
    }

    /// A smooth trace through the samples (-1...1), Catmull-Rom through the points, across `rect`.
    static func scopePath(samples: [Float], in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        guard samples.count > 1 else { return path }
        let points = samples.enumerated().map { i, s -> CGPoint in
            let v = CGFloat(min(max(s.isFinite ? s : 0, -1), 1))
            return CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(samples.count - 1), y: rect.midY - v * rect.height / 2)
        }
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// The low end's energy (the first bars), 0...1, which makes the light swell.
    static func bass(_ levels: [Float]) -> Float {
        let low = levels.prefix(4)
        guard !low.isEmpty else { return 0 }
        return min(max(low.reduce(0, +) / Float(low.count), 0), 1)
    }
}

final class ArtworkView: NSView {
    var palette = ArtworkPalette.make(genreKey: nil, tint: .default, dark: true) {
        didSet { if palette != oldValue { applyPalette() } }
    }
    var mode: ModernPlayerState.Visualizer = .spectrum {
        didSet { if mode != oldValue { modeChanged() } }
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
    private let barsHost = StillLayer()
    private let barsShape = StillShapeLayer()
    private let barsFill = StillGradientLayer()
    private let scope = StillShapeLayer()
    private let gloss = StillGradientLayer()
    private let rim = StillLayer()
    private var levels = [Float](repeating: 0, count: ModernVisualizerFrame.barCount)
    private var samples = [Float](repeating: 0, count: ModernVisualizerFrame.scopeCount)
    private var bassLevel: Float = 0
    private var isDark = true

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
        shade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.32)]
        shade.locations = [0.45, 1]
        clip.addSublayer(shade)
        barsFill.startPoint = CGPoint(x: 0.5, y: 1)
        barsFill.endPoint = CGPoint(x: 0.5, y: 0)
        barsFill.colors = [CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0.78)]
        barsFill.mask = barsShape
        barsHost.addSublayer(barsFill)
        barsHost.shadowColor = CGColor(gray: 1, alpha: 1)
        barsHost.shadowOpacity = 0.55
        barsHost.shadowRadius = 4
        barsHost.shadowOffset = .zero
        clip.addSublayer(barsHost)
        scope.fillColor = nil
        scope.strokeColor = CGColor(gray: 1, alpha: 0.95)
        scope.lineWidth = 1.6
        scope.lineCap = .round
        scope.lineJoin = .round
        scope.shadowColor = CGColor(gray: 1, alpha: 1)
        scope.shadowOpacity = 0.6
        scope.shadowRadius = 3.5
        scope.shadowOffset = .zero
        clip.addSublayer(scope)
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
        setAccessibilityLabel("Artwork and visualizer")
        setAccessibilityHelp("Changes the visualizer: spectrum, oscilloscope or off")
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

    func setDark(_ dark: Bool) {
        isDark = dark
        glowLayer.shadowOpacity = dark ? 0.55 : 0.4
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
        let inset = r.width * 0.12
        let barsRect = CGRect(x: inset, y: r.height * 0.42, width: r.width - inset * 2, height: r.height * 0.58 - inset * 0.85)
        barsHost.frame = r
        barsFill.frame = r
        barsShape.frame = r
        barsShape.path = VisualizerGeometry.barsPath(levels: levels, in: barsRect, gap: barsGap(barsRect))
        scope.frame = r
        scope.path = VisualizerGeometry.scopePath(samples: samples, in: r.insetBy(dx: inset * 0.8, dy: r.height * 0.3))
        gloss.frame = r
        if isAnimating { startDrift() }
    }

    private func barsGap(_ rect: CGRect) -> CGFloat { rect.width / CGFloat(ModernVisualizerFrame.barCount) * 0.34 }

    private func applyPalette() {
        base.colors = [palette.base.0.cgColor, palette.base.1.cgColor]
        for (i, (blob, color)) in zip(blobs, palette.blobs).enumerated() {
            let alpha = i == 0 ? 0.7 : 0.62
            blob.colors = [color.cgColor(alpha: alpha), color.cgColor(alpha: alpha * 0.45), color.cgColor(alpha: 0)]
            blob.locations = [0, 0.4, 1]
        }
        glowLayer.shadowColor = palette.blobs.first?.mixed(with: palette.base.1, 0.3).cgColor
        glowLayer.shadowRadius = 14
        glowLayer.shadowOffset = CGSize(width: 0, height: 8)
        glowLayer.shadowOpacity = isDark ? 0.55 : 0.4
    }

    private func modeChanged() {
        barsHost.isHidden = mode != .spectrum
        scope.isHidden = mode != .oscilloscope
        setAccessibilityLabel(mode == .off ? "Artwork" : "Artwork and visualizer")
    }

    // MARK: Motion

    private func animatingChanged() {
        if isAnimating {
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
            drift.values = (0...6).map { k -> NSValue in
                let t = Double(k) / 6 * 2 * .pi + phase
                return NSValue(point: CGPoint(x: p.x + a * CGFloat(cos(t)), y: p.y + a * 0.8 * CGFloat(sin(t * 1.3))))
            }
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

    /// One visualiser frame (nil: silence, when it stops: the bars settle to rest at once, no frames follow). Called at
    /// 30 Hz while animating.
    func update(with frame: ModernVisualizerFrame?) {
        guard let frame else { return settle() }
        // A touch of smoothing on top of the analyser's own falloff: quick to rise, gentle to fall.
        for i in 0..<levels.count {
            let target = i < frame.bars.count ? frame.bars[i] : 0
            levels[i] = target > levels[i] ? levels[i] + (target - levels[i]) * 0.7 : levels[i] + (target - levels[i]) * 0.35
        }
        for i in 0..<samples.count {
            samples[i] = i < frame.scope.count ? frame.scope[i] : 0
        }
        let r = bounds
        guard r.width > 0 else { return }
        let inset = r.width * 0.12
        let barsRect = CGRect(x: inset, y: r.height * 0.42, width: r.width - inset * 2, height: r.height * 0.58 - inset * 0.85)
        let interval = 1.0 / 30
        if mode == .spectrum {
            let path = VisualizerGeometry.barsPath(levels: levels, in: barsRect, gap: barsGap(barsRect))
            animatePath(barsShape, to: path, duration: interval)
        } else if mode == .oscilloscope {
            let path = VisualizerGeometry.scopePath(samples: samples, in: r.insetBy(dx: inset * 0.8, dy: r.height * 0.3))
            animatePath(scope, to: path, duration: interval)
        }
        // The light swells with the bass: one animation for the three blobs, scaled about the artwork's centre.
        let bass = VisualizerGeometry.bass(levels)
        bassLevel += (bass - bassLevel) * 0.4
        let swell = 1 + CGFloat(bassLevel) * 0.16
        let transform = Motion.scale(swell, around: blobHolder.bounds)
        if !Motion.reduced {
            let a = CABasicAnimation(keyPath: "sublayerTransform")
            a.fromValue = blobHolder.presentation()?.value(forKeyPath: "sublayerTransform")
                ?? NSValue(caTransform3D: blobHolder.sublayerTransform)
            a.toValue = NSValue(caTransform3D: transform)
            a.duration = interval
            blobHolder.add(a, forKey: "swell")
        }
        blobHolder.sublayerTransform = transform
        // Shadows are costly to redraw: follow the bass only in visible steps.
        let glow = (isDark ? 0.5 : 0.36) + bassLevel * 0.3
        if abs(glow - glowLayer.shadowOpacity) > 0.04 { glowLayer.shadowOpacity = glow }
    }

    /// Bars down, trace flat, light at rest, in a quarter of a second.
    private func settle() {
        levels = [Float](repeating: 0, count: levels.count)
        samples = [Float](repeating: 0, count: samples.count)
        bassLevel = 0
        let r = bounds
        guard r.width > 0 else { return }
        let inset = r.width * 0.12
        let barsRect = CGRect(x: inset, y: r.height * 0.42, width: r.width - inset * 2, height: r.height * 0.58 - inset * 0.85)
        animatePath(barsShape, to: VisualizerGeometry.barsPath(levels: levels, in: barsRect, gap: barsGap(barsRect)), duration: 0.25)
        animatePath(scope, to: VisualizerGeometry.scopePath(samples: samples, in: r.insetBy(dx: inset * 0.8, dy: r.height * 0.3)),
                    duration: 0.25)
        blobHolder.removeAnimation(forKey: "swell")
        blobHolder.sublayerTransform = CATransform3DIdentity
        glowLayer.shadowOpacity = isDark ? 0.55 : 0.4
    }

    /// Reduce Motion changed: drift starts or stops to match.
    func refreshMotion() {
        stopDrift()
        if isAnimating { startDrift() }
    }

    private func animatePath(_ layer: CAShapeLayer, to path: CGPath, duration: Double) {
        let from = layer.presentation()?.path ?? layer.path
        layer.path = path
        guard let from, !Motion.reduced else { return }
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = from
        a.toValue = path
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(a, forKey: "path")
    }
}
