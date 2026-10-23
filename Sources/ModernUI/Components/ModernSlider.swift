// SPDX-License-Identifier: GPL-3.0-or-later
// A capsule slider for volume, seeking and the EQ bands. The track thickens on hover; the knob (a white disc with a
// soft shadow) grows while dragged, or only appears on hover for the progress bar. Values snap to detents (0 dB, the
// middle) with a haptic tick, the scroll wheel nudges, and VoiceOver sees an adjustable slider. The value maths is
// pure (`SliderMath`) and unit-tested.

import AppKit
import QuartzCore

/// Value ↔ position along a slider's travel, and detent snapping.
nonisolated enum SliderMath {
    /// 0...1 for a point `position` along a travel from `start` to `end` (either direction).
    static func value(at position: CGFloat, start: CGFloat, end: CGFloat) -> Double {
        guard end != start else { return 0 }
        return min(max(Double((position - start) / (end - start)), 0), 1)
    }

    static func position(of value: Double, start: CGFloat, end: CGFloat) -> CGFloat {
        start + (end - start) * CGFloat(min(max(value, 0), 1))
    }

    /// The nearest detent within `radius`, else the value itself.
    static func snapped(_ value: Double, detents: [Double], radius: Double) -> Double {
        guard let nearest = detents.min(by: { abs($0 - value) < abs($1 - value) }), abs(nearest - value) <= radius
        else { return value }
        return nearest
    }
}

final class ModernSlider: NSControl {
    enum Axis { case horizontal, vertical }
    enum Phase { case began, changed, ended }

    let axis: Axis
    /// 0...1. Setting it while the user drags is ignored (the thumb follows the mouse).
    var value: Double = 0 {
        didSet {
            value = min(max(value.isFinite ? value : 0, 0), 1)
            if value != oldValue { needsLayout = true }
        }
    }
    /// Values that catch the thumb (0 dB on the EQ), with a haptic tick.
    var detents: [Double] = []
    var snapRadius: Double = 0.025
    /// The fill grows from here (0: from the start; 0.5: from the middle, for EQ gains).
    var fillOrigin: Double = 0
    /// false: the knob only shows on hover and while dragging (the progress bar).
    var knobAlwaysVisible = true
    /// Track thickness at rest; it grows by 2 points on hover.
    var trackThickness: CGFloat = 4
    var knobDiameter: CGFloat = 14
    /// A softer, colourless fill (the EQ while it is off; a live stream's bar).
    var muted = false { didSet { if muted != oldValue { applyFill() } } }
    /// Called while dragging (`changed`) and on release (`ended`).
    var onChange: ((Double, Phase) -> Void)?
    /// How much a VoiceOver increment or a wheel notch moves it.
    var step: Double = 0.05
    /// The scroll wheel adjusts it (not the progress bar: every notch would seek).
    var scrollWheelAdjusts = true
    var accessibilityValueText: ((Double) -> String)?

    private(set) var isDragging = false
    private var hovering = false
    private let track = StillLayer()
    private let fill = StillGradientLayer()
    private let knob = StillLayer()
    private let knobShine = StillGradientLayer()
    private var palette: ModernPalette?
    private var trackingArea: NSTrackingArea?
    private var lastDetent: Double?

    init(axis: Axis, label: String) {
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        track.masksToBounds = true
        layer?.addSublayer(track)
        fill.startPoint = axis == .horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 1)
        fill.endPoint = axis == .horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 0)
        track.addSublayer(fill)
        knob.shadowColor = CGColor(gray: 0, alpha: 1)
        knob.shadowOpacity = 0.28
        knob.shadowRadius = 3
        knob.shadowOffset = CGSize(width: 0, height: 1.5)
        knob.borderWidth = 0.5
        knob.borderColor = CGColor(gray: 0, alpha: 0.08)
        knobShine.colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.93, alpha: 1)]
        knobShine.masksToBounds = true
        knob.addSublayer(knobShine)
        layer?.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override var isEnabled: Bool {
        didSet {
            needsLayout = true
            setAccessibilityEnabled(isEnabled)
        }
    }

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        track.backgroundColor = palette.track
        knob.backgroundColor = palette.knob
        knob.shadowOpacity = palette.isDark ? 0.5 : 0.28
        applyFill()
    }

    private func applyFill() {
        guard let palette else { return }
        if muted {
            let grey = palette.isDark ? CGColor(gray: 1, alpha: 0.42) : CGColor(gray: 0, alpha: 0.32)
            fill.colors = [grey, grey]
        } else if fillOrigin > 0 {
            // From the middle (EQ gains): lighter, the curve carries the shape.
            let alpha = palette.isDark ? 0.6 : 0.5
            fill.colors = [palette.accent.cgColor(alpha: alpha), palette.accent.cgColor(alpha: alpha)]
        } else {
            fill.colors = [palette.accentDeep.cgColor, palette.accent.cgColor]
        }
    }

    // MARK: Geometry

    /// The travel's ends: where the knob's centre sits at 0 and at 1. A knob that only shows on hover travels the
    /// whole track (so a full progress bar is full).
    private var travel: (start: CGFloat, end: CGFloat) {
        let inset = knobAlwaysVisible ? knobDiameter / 2 : 0
        switch axis {
        case .horizontal: return (bounds.minX + inset, bounds.maxX - inset)
        // Vertical sliders grow upwards (the view is flipped).
        case .vertical: return (bounds.maxY - inset, bounds.minY + inset)
        }
    }

    override func layout() {
        super.layout()
        let thickness = trackThickness + ((hovering || isDragging) && isEnabled ? 2 : 0)
        let (start, end) = travel
        let knobPosition = SliderMath.position(of: value, start: start, end: end)
        let originPosition = SliderMath.position(of: fillOrigin, start: start, end: end)
        let trackRect: CGRect
        let fillRect: CGRect
        switch axis {
        case .horizontal:
            trackRect = CGRect(x: bounds.minX, y: bounds.midY - thickness / 2, width: bounds.width, height: thickness)
            let a = fillOrigin == 0 ? 0 : originPosition - trackRect.minX
            let b = fillOrigin == 0 && value <= 0 ? 0 : knobPosition - trackRect.minX
            fillRect = CGRect(x: min(a, b), y: 0, width: abs(b - a), height: thickness)
        case .vertical:
            trackRect = CGRect(x: bounds.midX - thickness / 2, y: bounds.minY, width: thickness, height: bounds.height)
            let a = fillOrigin == 0 ? trackRect.height : originPosition - trackRect.minY
            let b = fillOrigin == 0 && value <= 0 ? trackRect.height : knobPosition - trackRect.minY
            fillRect = CGRect(x: 0, y: min(a, b), width: thickness, height: abs(b - a))
        }
        track.frame = trackRect
        track.cornerRadius = thickness / 2
        fill.frame = fillRect
        fill.cornerRadius = fillOrigin == 0 ? thickness / 2 : 1
        let showKnob = isEnabled && (knobAlwaysVisible || hovering || isDragging)
        let d = knobDiameter * (isDragging ? 1.15 : 1)
        let center = axis == .horizontal ? CGPoint(x: knobPosition, y: bounds.midY) : CGPoint(x: bounds.midX, y: knobPosition)
        knob.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        knob.position = center
        knob.cornerRadius = d / 2
        knobShine.frame = knob.bounds
        knobShine.cornerRadius = d / 2
        knob.opacity = showKnob ? 1 : 0
        setAccessibilityValue(accessibilityValueText?(value) ?? "\(Int((value * 100).rounded()))%")
    }

    /// Animates the knob growing or fading (hover and drag changes).
    private func relayoutAnimated() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : 0.16)
        CATransaction.setAnimationTimingFunction(Motion.easeOut)
        // StillLayers ignore implicit actions; animate the few properties that change explicitly.
        let oldKnob = (knob.bounds, knob.opacity, track.frame)
        layout()
        CATransaction.commit()
        animateFrom(knobBounds: oldKnob.0, opacity: oldKnob.1, trackFrame: oldKnob.2)
    }

    private func animateFrom(knobBounds: CGRect, opacity: Float, trackFrame: CGRect) {
        guard !Motion.reduced else { return }
        let duration = 0.16
        if knobBounds != knob.bounds {
            for (key, from, to) in [("bounds", NSValue(rect: knobBounds), NSValue(rect: knob.bounds)),
                                    ("cornerRadius", knobBounds.width / 2 as NSNumber, knob.bounds.width / 2 as NSNumber)] {
                let a = CABasicAnimation(keyPath: key)
                a.fromValue = from
                a.toValue = to
                a.duration = duration
                a.timingFunction = Motion.easeOut
                knob.add(a, forKey: key)
                if key == "bounds" { knobShine.add(a, forKey: key) }
            }
        }
        if opacity != knob.opacity {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = opacity
            a.toValue = knob.opacity
            a.duration = duration
            knob.add(a, forKey: "opacity")
        }
        if trackFrame != track.frame {
            let a = CABasicAnimation(keyPath: "bounds")
            a.fromValue = NSValue(rect: CGRect(origin: .zero, size: trackFrame.size))
            a.toValue = NSValue(rect: CGRect(origin: .zero, size: track.frame.size))
            a.duration = duration
            a.timingFunction = Motion.easeOut
            track.add(a, forKey: "bounds")
        }
    }

    // MARK: Input

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
        relayoutAnimated()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        relayoutAnimated()
    }

    private func value(at event: NSEvent) -> Double {
        let p = convert(event.locationInWindow, from: nil)
        let (start, end) = travel
        let raw = SliderMath.value(at: axis == .horizontal ? p.x : p.y, start: start, end: end)
        return SliderMath.snapped(raw, detents: detents, radius: snapRadius)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDragging = true
        relayoutAnimated()
        // A double-click on an EQ slider resets it to its detent (0 dB).
        if event.clickCount == 2, let detent = detents.first {
            set(detent, phase: .began)
        } else {
            set(value(at: event), phase: .began)
        }
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { break }
            set(value(at: next), phase: .changed)
        }
        isDragging = false
        relayoutAnimated()
        onChange?(value, .ended)
        lastDetent = nil
    }

    private func set(_ newValue: Double, phase: Phase) {
        let detent = detents.first { $0 == newValue }
        if let detent, detent != lastDetent {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        lastDetent = detent
        let changed = newValue != value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        value = newValue
        layoutSubtreeIfNeeded()
        CATransaction.commit()
        if changed || phase == .began { onChange?(value, phase == .began ? .changed : phase) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, !isDragging, scrollWheelAdjusts else { return super.scrollWheel(with: event) }
        let delta = axis == .horizontal && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? -event.scrollingDeltaX : event.scrollingDeltaY
        guard delta != 0 else { return }
        let amount = event.hasPreciseScrollingDeltas ? Double(delta) / 400 : Double(delta) * step / 2
        let target = min(max(value + amount, 0), 1)
        guard target != value else { return }
        set(target, phase: .changed)
        onChange?(value, .ended)
    }

    override func accessibilityPerformIncrement() -> Bool {
        nudge(by: step)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        nudge(by: -step)
        return true
    }

    private func nudge(by amount: Double) {
        guard isEnabled else { return }
        set(min(max(value + amount, 0), 1), phase: .changed)
        onChange?(value, .ended)
    }

    /// Automation: drags to `fraction` as a user would (began, changed, ended).
    @discardableResult
    func drag(to fraction: Double) -> Bool {
        guard isEnabled else { return false }
        set(min(max(fraction, 0), 1), phase: .began)
        onChange?(value, .ended)
        return true
    }
}
