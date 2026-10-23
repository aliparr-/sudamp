// SPDX-License-Identifier: GPL-3.0-or-later
// One card of the modern window: Liquid Glass (NSGlassEffectView, macOS 26+) or, on macOS 15, a behind-window
// frosted material with its own rim light. Inside the glass, under the content: a frosted wash (milky or smoky,
// faintly tinted), a specular sheen across the top edge and a soft glow of the tint from the top-left corner. The
// drop shadow is drawn outside the glass by `CardShadowView`, so it never darkens the glass itself.
//
// The controls sit on a page of the card's natural size, pinned to the top of a clipping view inside the glass. A
// panel can then grow out of the card above it (the glass changes size; the page doesn't move or stretch, it is
// only revealed) and fade its page in: inside a glass container a glass view's own alpha is ignored, its content's
// isn't.

import AppKit
import QuartzCore

class GlassCard: NSView {
    /// Where the card's controls go (top-left origin): the page, always `naturalHeight` tall.
    let content: FlippedView = DragSurface()
    /// The card's full height; the glass may be shorter while it opens or closes.
    var naturalHeight: CGFloat = 100 {
        didSet { needsLayout = true }
    }
    private let clip: FlippedView = DragSurface()
    private let glass: NSView
    private let light = StillLayer()
    private let frost = StillLayer()
    private let sheen = StillGradientLayer()
    private let glow = StillGradientLayer()
    private let rim = StillLayer()
    private let usesSystemGlass: Bool
    private var palette: ModernPalette?

    var cornerRadius: CGFloat = Metrics.cardRadius {
        didSet { applyCornerRadius() }
    }

    /// `SUDAMP_GLASS=frosted` shows the macOS 15 material on any system (to check it).
    static let forceFallback = ProcessInfo.processInfo.environment["SUDAMP_GLASS"] == "frosted"

    static var systemGlassAvailable: Bool {
        if forceFallback { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    override init(frame frameRect: NSRect) {
        usesSystemGlass = Self.systemGlassAvailable
        if usesSystemGlass, #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: frameRect)
            g.style = .regular
            glass = g
        } else {
            let v = NSVisualEffectView(frame: frameRect)
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            glass = v
        }
        super.init(frame: frameRect)
        naturalHeight = frameRect.height
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        content.wantsLayer = true
        content.layer?.masksToBounds = false
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        addSubview(glass)
        if usesSystemGlass, #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.contentView = clip
        } else {
            clip.frame = bounds
            clip.autoresizingMask = [.width, .height]
            glass.addSubview(clip)
        }
        clip.addSubview(content)
        light.masksToBounds = true
        light.addSublayer(frost)
        light.addSublayer(glow)
        light.addSublayer(sheen)
        clip.layer?.addSublayer(light)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.12, y: 0)
        glow.endPoint = CGPoint(x: 0.95, y: 1.05)
        sheen.startPoint = CGPoint(x: 0.5, y: 0)
        sheen.endPoint = CGPoint(x: 0.5, y: 1)
        rim.borderWidth = 1
        rim.isHidden = usesSystemGlass
        layer?.addSublayer(rim)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyCornerRadius()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func applyCornerRadius() {
        if usesSystemGlass, #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.cornerRadius = cornerRadius
        } else {
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.cornerCurve = .continuous
        }
        light.cornerRadius = cornerRadius
        light.cornerCurve = .continuous
        clip.layer?.cornerRadius = cornerRadius
        clip.layer?.cornerCurve = .continuous
        rim.cornerRadius = cornerRadius
        rim.cornerCurve = .continuous
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        if !usesSystemGlass { clip.frame = glass.bounds }
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: naturalHeight)
        // From the card's own bounds: the glass may not have sized its content view yet. The light covers the glass
        // as it is (shorter while opening); the sheen and glow keep the page's proportions.
        light.frame = CGRect(origin: .zero, size: bounds.size)
        frost.frame = light.bounds
        glow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: naturalHeight)
        let sheenHeight = min(naturalHeight * 0.55, 120)
        sheen.frame = CGRect(x: 0, y: 0, width: bounds.width, height: sheenHeight)
        rim.frame = bounds
        // Keep the light at the very back.
        if clip.layer?.sublayers?.first !== light {
            light.removeFromSuperlayer()
            clip.layer?.insertSublayer(light, at: 0)
        }
    }

    /// The control (or the page) under `point`, in the superview's coordinates, found through the page alone: the
    /// glass view's own hit-testing is never asked.
    func routedHit(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point), let pageParent = content.superview else { return nil }
        let inParent = pageParent.convert(point, from: superview)
        guard content.frame.contains(inParent), bounds.contains(convert(point, from: superview)) else { return nil }
        return content.hitTest(inParent) ?? content
    }

    override func hitTest(_ point: NSPoint) -> NSView? { routedHit(point) }

    /// The page's bounds: what subclasses lay their controls out in.
    var page: CGRect { CGRect(x: 0, y: 0, width: bounds.width, height: naturalHeight) }

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        if usesSystemGlass, #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            g.tintColor = palette.glassTint
        } else if let v = glass as? NSVisualEffectView {
            v.material = palette.isDark ? .hudWindow : .popover
            v.layer?.backgroundColor = palette.glassTint?.withAlphaComponent((palette.glassTint?.alphaComponent ?? 0) * 0.8)
                .resolvedCGColor(in: palette.appearance)
            rim.borderColor = palette.isDark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 1, alpha: 0.55)
        }
        // Frost: a milky (light) or smoky (dark) wash, faintly tinted, so the glass reads as light or dark over any
        // desktop and the tint shows across the whole card.
        let wash = palette.isDark ? RGB(0.07, 0.07, 0.09) : RGB.white
        let tinted = palette.tint == .graphite ? wash : wash.mixed(with: palette.accent, palette.isDark ? 0.2 : 0.1)
        frost.backgroundColor = tinted.cgColor(alpha: palette.isDark ? 0.3 : 0.4)
        let accent = palette.accent
        let glowAlpha = palette.tint == .graphite ? 0.0 : (palette.isDark ? 0.26 : 0.2)
        glow.colors = [accent.cgColor(alpha: glowAlpha), accent.cgColor(alpha: glowAlpha * 0.35), accent.cgColor(alpha: 0)]
        glow.locations = [0, 0.45, 1]
        sheen.colors = [palette.sheen, palette.sheen.copy(alpha: 0) ?? CGColor(gray: 1, alpha: 0)]
        sheen.locations = [0, 1]
    }
}

/// Soft two-part drop shadows (a wide ambient one and a tight contact one) for every card, drawn behind the glass and
/// masked to outside each card, so the translucent glass never shows its own shadow through itself.
final class CardShadowView: FlippedView {
    private var shadows: [ObjectIdentifier: (ambient: StillShapeLayer, contact: StillShapeLayer, mask: StillShapeLayer,
                                             holder: StillLayer)] = [:]
    /// A nearly clear footprint under each card, outside the glass. WindowServer sends a click in a clear window to
    /// whatever is underneath wherever the window's own pixels are transparent, and Liquid Glass (with everything
    /// inside it) may be composited apart from them; these make the cards' areas the window's own, so clicks on a
    /// card come here while the margins between and around the cards stay click-through.
    private var plates: [ObjectIdentifier: StillLayer] = [:]
    static let plateColor = CGColor(gray: 0.5, alpha: 0.02)
    private var palette: ModernPalette?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        for entry in shadows.values { style(entry.ambient, contact: entry.contact) }
    }

    private func style(_ ambient: StillShapeLayer, contact: StillShapeLayer) {
        guard let palette else { return }
        for (layer, radius, offset, opacity) in [(ambient, CGFloat(26), CGFloat(16), palette.shadowOpacity),
                                                 (contact, CGFloat(5), CGFloat(2), palette.shadowOpacity * 0.55)] {
            layer.fillColor = CGColor(gray: 0, alpha: 1)
            layer.shadowColor = palette.shadow
            layer.shadowRadius = radius
            // The view is flipped: positive y is down.
            layer.shadowOffset = CGSize(width: 0, height: offset)
            layer.shadowOpacity = opacity
        }
    }

    /// Places the shadow for `card` at `frame` (in this view's coordinates), animating with the card when asked.
    func setShadow(for card: NSView, frame: CGRect, opacity: Float, animation: CAMediaTimingFunction?, duration: Double) {
        let key = ObjectIdentifier(card)
        let entry: (ambient: StillShapeLayer, contact: StillShapeLayer, mask: StillShapeLayer, holder: StillLayer)
        if let existing = shadows[key] {
            entry = existing
        } else {
            let holder = StillLayer()
            let ambient = StillShapeLayer()
            let contact = StillShapeLayer()
            let mask = StillShapeLayer()
            mask.fillRule = .evenOdd
            holder.mask = mask
            holder.addSublayer(ambient)
            holder.addSublayer(contact)
            layer?.addSublayer(holder)
            entry = (ambient, contact, mask, holder)
            shadows[key] = entry
            style(ambient, contact: contact)
        }
        let plate: StillLayer
        if let existing = plates[key] {
            plate = existing
        } else {
            plate = StillLayer()
            plate.backgroundColor = Self.plateColor
            plate.cornerRadius = Metrics.cardRadius
            plate.cornerCurve = .continuous
            layer?.insertSublayer(plate, at: 0)
            plates[key] = plate
        }
        plate.frame = frame
        plate.opacity = opacity > 0.001 ? 1 : 0
        let cardPath = roundedPath(CGRect(origin: .zero, size: frame.size), radius: Metrics.cardRadius)
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -200, dy: -200).offsetBy(dx: -frame.minX, dy: -frame.minY))
        outside.addPath(cardPath)
        // The shape itself is drawn under the card (covered by it) but masked away; only its shadow shows.
        let updates: [(CALayer, String, Any)] = [
            (entry.holder, "position", NSValue(point: frame.origin)),
            (entry.holder, "opacity", opacity),
            (entry.ambient, "path", cardPath), (entry.ambient, "shadowPath", cardPath),
            (entry.contact, "path", cardPath), (entry.contact, "shadowPath", cardPath),
            (entry.mask, "path", outside),
        ]
        entry.holder.anchorPoint = .zero
        entry.holder.bounds = CGRect(origin: .zero, size: frame.size)
        for (layer, keyPath, value) in updates {
            if let animation, duration > 0, !Motion.reduced || keyPath == "opacity" {
                Motion.animate(keyPath, on: layer, to: value, duration: duration, timing: animation)
            } else {
                layer.removeAnimation(forKey: keyPath)
                layer.setValue(value, forKeyPath: keyPath)
            }
        }
    }
}
