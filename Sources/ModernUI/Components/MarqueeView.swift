// SPDX-License-Identifier: GPL-3.0-or-later
// The scrolling title. Where the classic marquee jumps one 5-pixel character every 220 ms, this one glides: the
// title is drawn once (twice, with a gap, for a seamless loop) into a crisp bitmap at the screen's scale, and a
// Core Animation keyframe animation slides it at a steady 30 points a second after a short hold. The render server
// runs it at the display's own refresh rate (120 Hz on ProMotion) with no work on the main thread. The edges fade
// through a gradient mask while it moves. Titles that fit don't move; Reduce Motion truncates instead.

import AppKit
import QuartzCore

/// The marquee's timing, pure and unit-tested.
nonisolated struct MarqueeTiming: Equatable {
    /// Points per second.
    static let speed: CGFloat = 30
    /// Seconds the start of the title rests before (each loop of) the scroll.
    static let hold: Double = 2.4
    /// Space between the end of the title and its repeat.
    static let gap: CGFloat = 44

    /// How far one loop travels (title plus gap), its duration and the hold's share of it; nil when the title fits.
    static func loop(textWidth: CGFloat, viewWidth: CGFloat) -> (distance: CGFloat, duration: Double, holdFraction: Double)? {
        guard textWidth > viewWidth + 0.5, viewWidth > 0 else { return nil }
        let distance = textWidth + gap
        let travel = Double(distance / speed)
        let duration = hold + travel
        return (distance, duration, hold / duration)
    }
}

final class MarqueeView: NSView {
    var text = "" {
        didSet { if text != oldValue { rebuild() } }
    }
    var font: NSFont = .systemFont(ofSize: 16, weight: .semibold) {
        didSet { rebuild() }
    }
    var textColor: NSColor = .labelColor {
        didSet { rebuild() }
    }
    /// Frozen at the start (paused playback, nothing playing).
    var isScrolling = true {
        didSet { if isScrolling != oldValue { updateAnimation() } }
    }

    private let strip = StillLayer()
    private let fade = StillGradientLayer()
    private var textWidth: CGFloat = 0
    private var builtFor: (width: CGFloat, scale: CGFloat, appearance: String, text: String)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.anchorPoint = .zero
        strip.contentsGravity = .topLeft
        layer?.addSublayer(strip)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The title is a handle for the window, like the card around it.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        window.performDrag(with: event)
    }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuild()
    }

    private func rebuildIfNeeded() {
        let key = (bounds.width, backingScale, effectiveAppearance.name.rawValue, text)
        if let built = builtFor, built == key { return }
        rebuild()
    }

    private func attributes() -> [NSAttributedString.Key: Any] {
        var color = textColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(cgColor: textColor.cgColor) ?? textColor
        }
        return [.font: font, .foregroundColor: color]
    }

    private func rebuild() {
        setAccessibilityValue(text)
        toolTip = nil
        guard bounds.width > 0, window != nil || bounds.width > 0 else { return }
        let scale = backingScale
        builtFor = (bounds.width, scale, effectiveAppearance.name.rawValue, text)
        let attrs = attributes()
        let line = NSAttributedString(string: text, attributes: attrs)
        textWidth = ceil(line.size().width)
        let loop = Motion.reduced ? nil : MarqueeTiming.loop(textWidth: textWidth, viewWidth: bounds.width)
        let height = bounds.height
        let drawn: NSAttributedString
        let width: CGFloat
        if loop != nil {
            drawn = line
            width = textWidth * 2 + MarqueeTiming.gap
        } else if textWidth > bounds.width {
            // Reduce Motion: truncate, with the whole title in the tooltip.
            let truncated = NSMutableAttributedString(attributedString: line)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            truncated.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: truncated.length))
            drawn = truncated
            width = bounds.width
            toolTip = text
        } else {
            drawn = line
            width = max(1, textWidth)
        }
        strip.contents = render(drawn, repeated: loop != nil, width: width, height: height, scale: scale)
        strip.contentsScale = scale
        strip.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        strip.position = .zero
        updateAnimation()
    }

    private func render(_ string: NSAttributedString, repeated: Bool, width: CGFloat, height: CGFloat, scale: CGFloat) -> CGImage? {
        let pw = Int(ceil(width * scale)), ph = Int(ceil(height * scale))
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        // Flipped, top-left origin, like the view.
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let lineHeight = ceil(string.size().height)
        let y = floor((height - lineHeight) / 2)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        string.draw(with: CGRect(x: 0, y: y, width: repeated ? textWidth + 1 : width, height: lineHeight), options: options)
        if repeated {
            string.draw(with: CGRect(x: textWidth + MarqueeTiming.gap, y: y, width: textWidth + 1, height: lineHeight),
                        options: options)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func updateAnimation() {
        strip.removeAnimation(forKey: "scroll")
        fade.removeAnimation(forKey: "edges")
        let loop = Motion.reduced ? nil : MarqueeTiming.loop(textWidth: textWidth, viewWidth: bounds.width)
        guard let loop else {
            layer?.mask = nil
            return
        }
        fade.frame = bounds
        let edge = min(0.1, 16 / max(bounds.width, 1))
        let resting: [NSNumber] = [0, 0, NSNumber(value: 1 - edge), 1]
        let moving: [NSNumber] = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        fade.locations = resting
        layer?.mask = fade
        guard isScrolling else { return }
        let scroll = CAKeyframeAnimation(keyPath: "position.x")
        scroll.setKeyframes([0, 0, -Double(loop.distance)])
        scroll.keyTimes = [0, NSNumber(value: loop.holdFraction), 1]
        scroll.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .linear)]
        scroll.duration = loop.duration
        scroll.repeatCount = .infinity
        // Keep scrolling when the window is behind others; the render server owns it.
        scroll.isRemovedOnCompletion = false
        strip.add(scroll, forKey: "scroll")
        // The left edge fades in as the title starts to move and out as its repeat comes to rest.
        let ramp = min(0.35 / loop.duration, (1 - loop.holdFraction) / 4)
        let edges = CAKeyframeAnimation(keyPath: "locations")
        let restingArray = numberArray(resting.map(\.doubleValue))
        let movingArray = numberArray(moving.map(\.doubleValue))
        edges.setKeyframes(objects: [restingArray, restingArray, movingArray, movingArray, restingArray])
        edges.keyTimes = [0, NSNumber(value: loop.holdFraction), NSNumber(value: loop.holdFraction + ramp),
                          NSNumber(value: 1 - ramp), 1]
        edges.duration = loop.duration
        edges.repeatCount = .infinity
        edges.isRemovedOnCompletion = false
        fade.add(edges, forKey: "edges")
    }

    /// Reduce Motion changed: glide or truncate to match.
    func refreshMotion() { rebuild() }

    /// Whether the title is moving (for tests and automation).
    var isAnimating: Bool { strip.animation(forKey: "scroll") != nil }
}
