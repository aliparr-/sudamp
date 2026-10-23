// SPDX-License-Identifier: GPL-3.0-or-later
// The appearance popover, opened from the player's half-circle button: Automatic, Light or Dark; the tint, as a
// grid of swatches like System Settings' accent colours; and the way back to the classic skins. Changes apply live.

import AppKit
import QuartzCore

final class AppearancePopover: NSViewController {
    var onEvent: ((ModernEvent) -> Void)?
    private var appearanceChoice: ModernAppearance
    private var tintChoice: ModernTint
    private let segmented = NSSegmentedControl(labels: ModernAppearance.allCases.map(\.title), trackingMode: .selectOne,
                                               target: nil, action: nil)
    private var swatches: [TintSwatch] = []
    private let tintName = makeLabel(size: 11, weight: .medium, color: .secondaryLabelColor)

    init(appearance: ModernAppearance, tint: ModernTint) {
        appearanceChoice = appearance
        tintChoice = tint
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let width: CGFloat = 288
        let root = FlippedView(frame: CGRect(x: 0, y: 0, width: width, height: 246))
        let p: CGFloat = 16
        var y: CGFloat = 14
        let appearanceTitle = makeLabel("Appearance", size: 11, weight: .semibold, color: .secondaryLabelColor)
        appearanceTitle.frame = CGRect(x: p, y: y, width: width - p * 2, height: 15)
        root.addSubview(appearanceTitle)
        y += 21
        segmented.target = self
        segmented.action = #selector(appearanceChanged(_:))
        segmented.segmentDistribution = .fillEqually
        segmented.selectedSegment = ModernAppearance.allCases.firstIndex(of: appearanceChoice) ?? 0
        segmented.frame = CGRect(x: p, y: y, width: width - p * 2, height: 24)
        for (i, mode) in ModernAppearance.allCases.enumerated() {
            let symbol = switch mode {
            case .auto: "circle.lefthalf.filled"
            case .light: "sun.max.fill"
            case .dark: "moon.fill"
            }
            segmented.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), forSegment: i)
        }
        root.addSubview(segmented)
        y += 38
        let tintTitle = makeLabel("Tint", size: 11, weight: .semibold, color: .secondaryLabelColor)
        tintTitle.frame = CGRect(x: p, y: y, width: 80, height: 15)
        root.addSubview(tintTitle)
        tintName.alignment = .right
        tintName.frame = CGRect(x: width - p - 120, y: y, width: 120, height: 15)
        root.addSubview(tintName)
        y += 22
        let columns = 6
        let size: CGFloat = 30
        let spacing = (width - p * 2 - size * CGFloat(columns)) / CGFloat(columns - 1)
        for (i, tint) in ModernTint.allCases.enumerated() {
            let swatch = TintSwatch(tint: tint)
            swatch.frame = CGRect(x: p + CGFloat(i % columns) * (size + spacing), y: y + CGFloat(i / columns) * (size + 10),
                                  width: size, height: size)
            swatch.onPick = { [weak self] in self?.pick(tint) }
            root.addSubview(swatch)
            swatches.append(swatch)
        }
        y += (size + 10) * 2 + 6
        let separator = NSBox()
        separator.boxType = .separator
        separator.frame = CGRect(x: p, y: y, width: width - p * 2, height: 1)
        root.addSubview(separator)
        y += 12
        let classic = NSButton(title: "Switch to Classic Skins", target: self, action: #selector(switchToClassic(_:)))
        classic.image = NSImage(systemSymbolName: "square.stack.3d.down.right", accessibilityDescription: nil)
        classic.imagePosition = .imageLeading
        classic.controlSize = .regular
        classic.bezelStyle = .push
        classic.frame = CGRect(x: p - 4, y: y, width: width - p * 2 + 8, height: 30)
        classic.toolTip = "Use the Winamp-style .wsz skins (Skins menu)"
        root.addSubview(classic)
        y += 30 + 12
        root.frame.size.height = y
        view = root
        preferredContentSize = root.frame.size
        updateSelection()
    }

    private func updateSelection() {
        for swatch in swatches { swatch.isSelected = swatch.tint == tintChoice }
        tintName.stringValue = tintChoice.title
    }

    private func pick(_ tint: ModernTint) {
        tintChoice = tint
        updateSelection()
        onEvent?(.setTint(tint))
    }

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        let mode = ModernAppearance.allCases[max(0, sender.selectedSegment)]
        appearanceChoice = mode
        onEvent?(.setAppearance(mode))
    }

    @objc private func switchToClassic(_ sender: Any?) {
        onEvent?(.switchToClassic)
    }
}

/// One tint: a glossy disc of its colour, ringed when chosen.
final class TintSwatch: NSView {
    let tint: ModernTint
    var onPick: (() -> Void)?
    var isSelected = false { didSet { updateRing() } }
    private let disc = StillGradientLayer()
    private let ring = StillShapeLayer()
    private let check = PassiveImageView()

    init(tint: ModernTint) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 2
        layer?.addSublayer(ring)
        disc.startPoint = CGPoint(x: 0.2, y: 0)
        disc.endPoint = CGPoint(x: 0.8, y: 1)
        disc.masksToBounds = true
        disc.borderWidth = 0.5
        disc.borderColor = CGColor(gray: 0, alpha: 0.12)
        layer?.addSublayer(disc)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .heavy))
        check.contentTintColor = .white
        check.imageScaling = .scaleNone
        addSubview(check)
        toolTip = tint.title
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(tint.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The whole control takes the click, never the image or text inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        // `point` is in the superview's coordinates, like `frame`.
        return frame.contains(point) ? self : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = effectiveAppearance.isDark
        let c = dark ? tint.accent.dark : tint.accent.light
        disc.colors = [c.adjusted(brightness: 1.1).cgColor, tint.deep(dark: dark).cgColor]
        ring.strokeColor = c.cgColor
        check.contentTintColor = c.contrast(with: .white) >= 2.2 ? .white : NSColor(white: 0.1, alpha: 1)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 4
        disc.frame = bounds.insetBy(dx: inset, dy: inset)
        disc.cornerRadius = disc.frame.width / 2
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        check.frame = bounds
        updateColors()
        updateRing()
    }

    private func updateRing() {
        ring.opacity = isSelected ? 1 : 0
        check.isHidden = !isSelected
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    /// Claimed, so the mouse-up comes here (passed up, the card would start a window drag and take it).
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPick?()
        return true
    }
}
