// SPDX-License-Identifier: GPL-3.0-or-later
// An on/off switch in the tint (NSSwitch only ever takes the system accent): a capsule that fills with the accent
// gradient and a white knob that springs across.

import AppKit
import QuartzCore

final class ModernSwitch: NSControl {
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            update(animated: window != nil)
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }
    var onToggle: ((Bool) -> Void)?

    private let track = StillGradientLayer()
    private let knob = StillLayer()
    private var palette: ModernPalette?
    static let size = CGSize(width: 34, height: 20)

    init(label: String) {
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.masksToBounds = false
        track.startPoint = CGPoint(x: 0, y: 0.5)
        track.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(track)
        knob.backgroundColor = CGColor(gray: 1, alpha: 1)
        knob.shadowColor = CGColor(gray: 0, alpha: 1)
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 2.5
        knob.shadowOffset = CGSize(width: 0, height: 1)
        layer?.addSublayer(knob)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        setAccessibilityValue(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    func apply(_ palette: ModernPalette) {
        self.palette = palette
        update(animated: false)
    }

    override func layout() {
        super.layout()
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        update(animated: false)
    }

    private func knobFrame(on: Bool) -> CGRect {
        let d = bounds.height - 4
        return CGRect(x: on ? bounds.width - d - 2 : 2, y: 2, width: d, height: d)
    }

    private func update(animated: Bool) {
        guard let palette else { return }
        let off = palette.isDark ? CGColor(gray: 1, alpha: 0.18) : CGColor(gray: 0, alpha: 0.14)
        track.colors = isOn ? [palette.accentDeep.cgColor, palette.accent.cgColor] : [off, off]
        let frame = knobFrame(on: isOn)
        knob.cornerRadius = frame.height / 2
        knob.bounds = CGRect(origin: .zero, size: frame.size)
        let center = NSValue(point: CGPoint(x: frame.midX, y: frame.midY))
        if animated {
            Motion.spring("position", on: knob, to: center, damping: 15, stiffness: 300)
        } else {
            knob.removeAnimation(forKey: "position")
            knob.position = CGPoint(x: frame.midX, y: frame.midY)
        }
    }

    /// Claimed, so the mouse-up comes here (passed up, the card would start a window drag and take it).
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }

    func toggle() {
        isOn.toggle()
        onToggle?(isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
}
