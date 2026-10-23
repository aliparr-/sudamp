// SPDX-License-Identifier: GPL-3.0-or-later
// The smaller pieces of the modern window: the genre button (DESIGN §3: picking a genre is the one action that
// matters, so with none chosen it is a glowing, filled prompt; afterwards a tinted chip naming the genre), source and
// LIVE badges, and the window's close and minimise lights.

import AppKit
import QuartzCore

/// A capsule button with a title and a trailing chevron that opens a menu (the genre, the EQ presets).
final class CapsuleButton: NSControl {
    enum Style {
        /// Tinted wash, accent text.
        case chip
        /// Filled accent with a breathing glow: asks to be clicked.
        case prompt
        /// Quiet: a neutral wash, primary text (the presets button).
        case neutral
    }

    var style: Style = .chip {
        didSet { if style != oldValue { applyStyle() } }
    }
    var title = "" {
        didSet {
            label.stringValue = title
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    var leadingSymbol: String? {
        didSet { updateLeading() }
    }
    /// The trailing chevron: menus have one, plain actions (Retry) don't.
    var showsChevron = true {
        didSet {
            chevron.isHidden = !showsChevron
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    var onPress: (() -> Void)?
    var titleFont: NSFont = .systemFont(ofSize: 12, weight: .semibold) {
        didSet {
            label.font = titleFont
            invalidateIntrinsicContentSize()
        }
    }

    private let background = StillGradientLayer()
    private let glow = StillShapeLayer()
    private let label = makeLabel(size: 12, weight: .semibold)
    private let chevron = PassiveImageView()
    private let leading = PassiveImageView()
    private var palette: ModernPalette?
    private var hovering = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?

    init(label text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        glow.fillColor = CGColor(gray: 0, alpha: 1)
        glow.opacity = 0
        layer?.addSublayer(glow)
        background.startPoint = CGPoint(x: 0, y: 0)
        background.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(background)
        label.font = titleFont
        addSubview(label)
        let config = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        chevron.imageScaling = .scaleNone
        addSubview(chevron)
        leading.imageScaling = .scaleNone
        leading.isHidden = true
        addSubview(leading)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        title = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole control takes the click, never the image or text inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        // `point` is in the superview's coordinates, like `frame`.
        return frame.contains(point) ? self : nil
    }

    private var horizontalPadding: CGFloat { style == .prompt ? 14 : 11 }

    /// The width the title needs, padding and chevron included.
    var fittingWidth: CGFloat {
        let text = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let lead: CGFloat = leadingSymbol == nil ? 0 : 18
        // NSTextField insets its text by a couple of points on each side.
        return horizontalPadding * 2 + lead + text + 6 + (showsChevron ? 5 + 9 : 0)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: fittingWidth, height: 26) }

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        applyStyle()
    }

    private func updateLeading() {
        guard let leadingSymbol else {
            leading.isHidden = true
            needsLayout = true
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        leading.image = NSImage(systemSymbolName: leadingSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        leading.isHidden = false
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyStyle() {
        guard let palette else { return }
        let textColor: NSColor
        switch style {
        case .chip:
            let alpha = hovering ? (palette.isDark ? 0.3 : 0.2) : (palette.isDark ? 0.2 : 0.13)
            background.colors = [palette.accent.cgColor(alpha: alpha), palette.accent.cgColor(alpha: alpha)]
            textColor = palette.accentColor
            stopBreathing()
        case .prompt:
            let lift = hovering ? 1.08 : 1
            background.colors = [palette.accent.adjusted(brightness: 1.06 * lift).cgColor, palette.accentDeep.adjusted(brightness: lift).cgColor]
            textColor = palette.onAccent.nsColor
            glow.shadowColor = palette.accent.cgColor
            glow.shadowRadius = 10
            glow.shadowOffset = CGSize(width: 0, height: 3)
            glow.shadowOpacity = 1
            startBreathing()
        case .neutral:
            let c = hovering ? palette.pressed : palette.hover
            background.colors = [c, c]
            textColor = .labelColor
            stopBreathing()
        }
        label.textColor = textColor
        chevron.contentTintColor = textColor.withAlphaComponent(style == .prompt ? 0.9 : 0.75)
        leading.contentTintColor = textColor
        needsLayout = true
    }

    private func startBreathing() {
        guard glow.animation(forKey: "breathe") == nil else { return }
        glow.opacity = 0.45
        guard !Motion.reduced else { return }
        // A few breaths to catch the eye, then it rests (an endless glow would keep the window compositing).
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.25
        breathe.toValue = 0.75
        breathe.duration = 1.6
        breathe.autoreverses = true
        breathe.repeatCount = 6
        breathe.timingFunction = Motion.easeInOut
        glow.add(breathe, forKey: "breathe")
    }

    private func stopBreathing() {
        glow.removeAllAnimations()
        glow.opacity = 0
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        background.frame = bounds
        background.cornerRadius = h / 2
        glow.path = roundedPath(bounds.insetBy(dx: 3, dy: 3), radius: h / 2)
        glow.shadowPath = glow.path
        var x = horizontalPadding
        if !leading.isHidden {
            leading.frame = CGRect(x: x - 2, y: 0, width: 16, height: h)
            x += 18
        }
        let chevronWidth: CGFloat = showsChevron ? 9 : -4
        let labelHeight: CGFloat = ceil(titleFont.ascender - titleFont.descender + 1)
        label.frame = CGRect(x: x, y: floor((h - labelHeight) / 2), width: max(0, bounds.width - x - horizontalPadding - chevronWidth - 4),
                             height: labelHeight)
        chevron.frame = CGRect(x: bounds.width - horizontalPadding - chevronWidth, y: 1, width: chevronWidth, height: h)
        layer?.sublayerTransform = Motion.scale(pressed ? 0.95 : 1, around: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let layer else { return }
        pressed = true
        Motion.spring("sublayerTransform", on: layer, to: NSValue(caTransform3D: Motion.scale(0.95, around: bounds)),
                      damping: 22, stiffness: 600)
        // Menus open on mouse-down, as pop-up buttons do.
        performPress()
        pressed = false
        Motion.spring("sublayerTransform", on: layer, to: NSValue(caTransform3D: Motion.scale(1, around: bounds)),
                      damping: 14, stiffness: 300)
    }

    func performPress() {
        onPress?()
        if let action { sendAction(action, to: target) }
    }

    override func accessibilityPerformPress() -> Bool {
        performPress()
        return true
    }
}

/// A small rounded badge: the source (`SoundCloud`), `LIVE` with a pulsing dot, or quiet format text.
final class BadgeView: NSView {
    enum Kind {
        case source(ModernPlayerState.SourceTag)
        case live
    }

    var kind: Kind = .live {
        didSet { update() }
    }
    /// Short tags (`YT`, `SC`) for the station list.
    var compact = false {
        didSet { update() }
    }

    private let label = makeLabel(size: 9.5, weight: .bold)
    private let background = StillLayer()
    private let dot = StillLayer()
    private var palette: ModernPalette?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(background)
        background.cornerCurve = .continuous
        dot.cornerRadius = 2.5
        layer?.addSublayer(dot)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        update()
    }

    static func color(for tag: ModernPlayerState.SourceTag, dark: Bool) -> RGB {
        switch tag {
        case .youtube: dark ? RGB(hex: 0xFF6B6B) : RGB(hex: 0xD92D2D)
        case .soundcloud: dark ? RGB(hex: 0xFF9A4D) : RGB(hex: 0xE0620F)
        case .mixcloud: dark ? RGB(hex: 0x8FA2FF) : RGB(hex: 0x4D5FD6)
        case .radio: dark ? RGB(hex: 0x6FD6A8) : RGB(hex: 0x16915C)
        }
    }

    private func update() {
        guard let palette else { return }
        let color: RGB
        switch kind {
        case .source(let tag):
            color = Self.color(for: tag, dark: palette.isDark)
            label.stringValue = compact ? tag.rawValue : tag.name.uppercased()
            dot.isHidden = true
            dot.removeAllAnimations()
        case .live:
            color = palette.isDark ? RGB(hex: 0xFF5A5F) : RGB(hex: 0xE5383B)
            label.stringValue = "LIVE"
            dot.isHidden = false
            dot.backgroundColor = color.cgColor
            if dot.animation(forKey: "pulse") == nil, !Motion.reduced {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.25
                pulse.duration = 0.9
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = Motion.easeInOut
                dot.add(pulse, forKey: "pulse")
            }
        }
        label.textColor = color.nsColor
        background.backgroundColor = color.cgColor(alpha: palette.isDark ? 0.2 : 0.12)
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font!, .kern: 0.6]
        label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: attributes.merging(
            [.foregroundColor: color.nsColor], uniquingKeysWith: { $1 }))
        setAccessibilityLabel(label.stringValue)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    var fittingWidth: CGFloat {
        let text = ceil(label.attributedStringValue.size().width)
        return text + 14 + (dot.isHidden ? 0 : 9)
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        background.cornerRadius = 5
        var x: CGFloat = compact ? 0 : 4
        if !dot.isHidden {
            dot.frame = CGRect(x: x + 2, y: (bounds.height - 5) / 2, width: 5, height: 5)
            x += 9
        }
        let h = ceil(label.attributedStringValue.size().height)
        label.alignment = compact ? .center : .left
        label.frame = CGRect(x: x, y: floor((bounds.height - h) / 2), width: bounds.width - x - (compact ? 0 : 2), height: h)
    }
}

/// One drawn window light as an accessibility button (VoiceOver calls in on the main thread, as SkinUI's elements
/// assume).
nonisolated final class LightElement: NSAccessibilityElement {
    private let isClose: Bool
    private weak var lights: WindowLights?

    init(close: Bool, lights: WindowLights) {
        isClose = close
        self.lights = lights
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        let lights = self.lights, close = isClose
        return MainActor.assumeIsolated {
            guard let lights else { return false }
            if close { lights.onClose?() } else { lights.onMinimize?() }
            return true
        }
    }
}

/// Close and minimise, drawn like the system's window lights (a borderless window has none of its own). They fade in
/// while the pointer is over the player and show their glyphs while it is over them.
final class WindowLights: NSView {
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?

    private let close = StillShapeLayer()
    private let minimize = StillShapeLayer()
    private let closeGlyph = StillShapeLayer()
    private let minimizeGlyph = StillShapeLayer()
    private var trackingArea: NSTrackingArea?
    static let diameter: CGFloat = 12
    static let spacing: CGFloat = 8

    static var size: CGSize { CGSize(width: diameter * 2 + spacing, height: diameter) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for (light, fill) in [(close, RGB(hex: 0xFF5F57)), (minimize, RGB(hex: 0xFEBC2E))] {
            light.fillColor = fill.cgColor
            light.strokeColor = fill.adjusted(brightness: 0.78).cgColor(alpha: 0.6)
            light.lineWidth = 0.5
            layer?.addSublayer(light)
        }
        for glyph in [closeGlyph, minimizeGlyph] {
            glyph.strokeColor = CGColor(gray: 0, alpha: 0.55)
            glyph.lineWidth = 1.2
            glyph.lineCap = .round
            glyph.opacity = 0
            layer?.addSublayer(glyph)
        }
        alphaValue = 0
        setAccessibilityElement(false)
    }

    /// Close and Minimize as buttons for VoiceOver (they are drawn, not views).
    override func accessibilityChildren() -> [Any]? {
        let d = Self.diameter
        return [("Close", CGRect(x: 0, y: 0, width: d, height: d), true),
                ("Minimize", CGRect(x: d + Self.spacing, y: 0, width: d, height: d), false)].map { title, rect, close in
            let element = LightElement(close: close, lights: self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(title)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect)
            return element
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let d = Self.diameter
        let closeRect = CGRect(x: 0, y: 0, width: d, height: d)
        let minRect = CGRect(x: d + Self.spacing, y: 0, width: d, height: d)
        close.path = CGPath(ellipseIn: closeRect.insetBy(dx: 0.25, dy: 0.25), transform: nil)
        minimize.path = CGPath(ellipseIn: minRect.insetBy(dx: 0.25, dy: 0.25), transform: nil)
        let x = CGMutablePath()
        let k: CGFloat = 3.4
        x.move(to: CGPoint(x: closeRect.midX - k, y: closeRect.midY - k))
        x.addLine(to: CGPoint(x: closeRect.midX + k, y: closeRect.midY + k))
        x.move(to: CGPoint(x: closeRect.midX + k, y: closeRect.midY - k))
        x.addLine(to: CGPoint(x: closeRect.midX - k, y: closeRect.midY + k))
        closeGlyph.path = x
        let m = CGMutablePath()
        m.move(to: CGPoint(x: minRect.midX - 3.8, y: minRect.midY))
        m.addLine(to: CGPoint(x: minRect.midX + 3.8, y: minRect.midY))
        minimizeGlyph.path = m
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: -4, dy: -4), options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setGlyphs(true) }
    override func mouseExited(with event: NSEvent) { setGlyphs(false) }

    private func setGlyphs(_ on: Bool) {
        for glyph in [closeGlyph, minimizeGlyph] {
            Motion.animate("opacity", on: glyph, to: Float(on ? 1 : 0), duration: 0.12)
        }
    }

    /// Claimed, so the mouse-up comes here (passed up, the card would start a window drag and take it).
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.x <= Self.diameter + Self.spacing / 2 {
            onClose?()
        } else {
            onMinimize?()
        }
    }

    private(set) var isShown = false

    /// Shown while the pointer is over the player card.
    func setVisible(_ visible: Bool) {
        guard visible != isShown else { return }
        isShown = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.18 : 0.3
            animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Invisible lights take no clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { isShown ? super.hitTest(point) : nil }
}
