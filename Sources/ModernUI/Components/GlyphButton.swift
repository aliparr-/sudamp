// SPDX-License-Identifier: GPL-3.0-or-later
// The modern skin's buttons: an SF Symbol on glass. Plain buttons show a soft wash on hover and sink a little when
// pressed, springing back on release; the prominent style (play/pause) is a disc of the accent gradient with a
// coloured glow under it, a specular highlight on top, and a spinning ring while a stream tunes. Symbol changes use
// SF Symbols' replace transition (play ↔ pause morphs, a heart fills and bounces).

import AppKit
import QuartzCore
import Symbols

final class GlyphButton: NSControl {
    enum Style {
        /// A glyph with a round hover wash.
        case plain
        /// A filled accent disc (play/pause).
        case prominent
    }

    enum Tone {
        case primary, secondary, accent
    }

    let style: Style
    private(set) var symbolName: String
    var pointSize: CGFloat { didSet { updateImage(animated: false) } }
    var weight: NSFont.Weight { didSet { updateImage(animated: false) } }
    var tone: Tone = .primary { didSet { updateColors() } }
    /// Lit: drawn in the accent (a toggle that is on).
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            updateColors()
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }
    /// Tuning: the prominent disc shows a spinning ring.
    var isWorking = false {
        didSet { if isWorking != oldValue { updateSpinner() } }
    }
    var onPress: (() -> Void)?

    private let imageView = NSImageView()
    private let wash = StillLayer()
    private let disc = StillGradientLayer()
    private let discHighlight = StillGradientLayer()
    private let glow = StillShapeLayer()
    private let ring = StillShapeLayer()
    private let ringTrack = StillShapeLayer()
    private var palette: ModernPalette?
    private var hovering = false
    private var pressing = false
    private var trackingArea: NSTrackingArea?

    init(symbol: String, pointSize: CGFloat = 15, weight: NSFont.Weight = .semibold, style: Style = .plain,
         label: String) {
        symbolName = symbol
        self.pointSize = pointSize
        self.weight = weight
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
        if style == .prominent {
            glow.fillColor = nil
            layer?.addSublayer(glow)
            disc.startPoint = CGPoint(x: 0.15, y: 0)
            disc.endPoint = CGPoint(x: 0.85, y: 1)
            disc.masksToBounds = true
            layer?.addSublayer(disc)
            discHighlight.startPoint = CGPoint(x: 0.5, y: 0)
            discHighlight.endPoint = CGPoint(x: 0.5, y: 0.6)
            discHighlight.colors = [CGColor(gray: 1, alpha: 0.42), CGColor(gray: 1, alpha: 0)]
            disc.addSublayer(discHighlight)
            ring.fillColor = nil
            ring.lineWidth = 2.5
            ring.lineCap = .round
            ring.strokeStart = 0
            ring.strokeEnd = 0.28
            ring.isHidden = true
            ringTrack.fillColor = nil
            ringTrack.lineWidth = 2.5
            ringTrack.isHidden = true
            layer?.addSublayer(ringTrack)
            layer?.addSublayer(ring)
        } else {
            wash.opacity = 0
            layer?.addSublayer(wash)
        }
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        imageView.refusesFirstResponder = true
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        updateImage(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.38
            setAccessibilityEnabled(isEnabled)
            if !isEnabled, style == .plain {
                wash.removeAllAnimations()
                wash.opacity = 0
            }
        }
    }

    /// A toggle (favourite, shuffle, the panel buttons) says whether it is on.
    var isToggle = false {
        didSet {
            setAccessibilityRole(isToggle ? .checkBox : .button)
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }

    // MARK: Look

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        if style == .prominent {
            disc.colors = [palette.accent.adjusted(brightness: 1.08).cgColor, palette.accentDeep.cgColor]
            glow.shadowColor = palette.accent.cgColor
            glow.shadowOpacity = palette.isDark ? 0.55 : 0.45
            glow.shadowRadius = 12
            glow.shadowOffset = CGSize(width: 0, height: 5)
            ring.strokeColor = palette.onAccent.cgColor(alpha: 0.95)
            ringTrack.strokeColor = palette.onAccent.cgColor(alpha: 0.22)
        } else {
            wash.backgroundColor = palette.hover
        }
        updateColors()
    }

    private func updateColors() {
        let color: NSColor
        if style == .prominent {
            color = palette?.onAccent.nsColor ?? .white
        } else if isOn || tone == .accent {
            color = palette?.accentColor ?? .controlAccentColor
        } else {
            color = tone == .secondary ? .secondaryLabelColor : .labelColor
        }
        imageView.contentTintColor = color
    }

    /// Changes the symbol; `animated` morphs it with SF Symbols' replace transition.
    func setSymbol(_ name: String, animated: Bool) {
        guard name != symbolName else { return }
        symbolName = name
        updateImage(animated: animated)
    }

    /// A one-off bounce (a favourite added).
    func bounce() {
        guard !Motion.reduced else { return }
        imageView.addSymbolEffect(.bounce.up, options: .nonRepeating)
    }

    private func updateImage(animated: Bool) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .medium)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel())?
            .withSymbolConfiguration(configuration) else { return }
        image.isTemplate = true
        if animated, !Motion.reduced, imageView.image != nil {
            imageView.setSymbolImage(image, contentTransition: .replace.downUp.byLayer)
        } else {
            imageView.image = image
        }
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let d = min(bounds.width, bounds.height)
        let circle = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        wash.frame = circle
        wash.cornerRadius = d / 2
        disc.frame = circle
        disc.cornerRadius = d / 2
        discHighlight.frame = disc.bounds
        let glowRect = circle.insetBy(dx: 4, dy: 4)
        glow.path = CGPath(ellipseIn: glowRect, transform: nil)
        glow.shadowPath = glow.path
        ring.frame = circle
        ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: circle.size).insetBy(dx: 5, dy: 5), transform: nil)
        ringTrack.frame = circle
        ringTrack.path = ring.path
        layer?.sublayerTransform = Motion.scale(pressing ? 0.88 : 1, around: bounds)
    }

    private func updateSpinner() {
        guard style == .prominent else { return }
        ring.isHidden = !isWorking
        ringTrack.isHidden = !isWorking
        if isWorking {
            imageView.alphaValue = 0.55
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = Motion.reduced ? 2.4 : 0.9
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
            let breathe = CABasicAnimation(keyPath: "strokeEnd")
            breathe.fromValue = 0.18
            breathe.toValue = 0.42
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            ring.add(breathe, forKey: "breathe")
        } else {
            imageView.alphaValue = 1
            ring.removeAllAnimations()
        }
    }

    // MARK: Mouse

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
        updateHover()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateHover()
    }

    private func updateHover() {
        guard isEnabled else { return }
        if style == .plain {
            Motion.animate("opacity", on: wash, to: Float(hovering ? 1 : 0), duration: hovering ? 0.12 : 0.25)
        } else {
            Motion.animate("shadowRadius", on: glow, to: CGFloat(hovering ? 16 : 12), duration: 0.25)
            Motion.animate("shadowOpacity", on: glow, to: Float((palette?.isDark ?? false ? 0.55 : 0.45) + (hovering ? 0.15 : 0)),
                           duration: 0.25)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setPressed(true)
        // Track until release, like NSButton: the press counts only if released inside.
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = convert(next.locationInWindow, from: nil)
            inside = bounds.contains(point)
            if next.type == .leftMouseUp { break }
            setPressed(inside)
        }
        setPressed(false)
        if inside { performPress() }
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != pressing, let layer else { return }
        pressing = pressed
        Motion.spring("sublayerTransform", on: layer, to: NSValue(caTransform3D: Motion.scale(pressed ? 0.88 : 1, around: bounds)),
                      damping: pressed ? 22 : 13, stiffness: pressed ? 600 : 320)
        if style == .plain {
            wash.backgroundColor = pressed ? palette?.pressed : palette?.hover
            if pressed { wash.opacity = 1 }
        }
    }

    func performPress() {
        onPress?()
        if let action { sendAction(action, to: target) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performPress()
        return true
    }
}
