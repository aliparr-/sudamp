// SPDX-License-Identifier: GPL-3.0-or-later
// The appearance popover, opened from the player's half-circle button: Automatic, Light or Dark; the tint, as a
// grid of swatches like System Settings' accent colours; the visualiser (a grid of its scenes, Rotate and Off, how
// often it rotates, and what colours the artwork behind it); and the way back to the classic skins. Changes apply
// live.

import AppKit
import QuartzCore

final class AppearancePopover: NSViewController {
    typealias Visualizer = ModernPlayerState.Visualizer

    var onEvent: ((ModernEvent) -> Void)?
    private var appearanceChoice: ModernAppearance
    private var tintChoice: ModernTint
    private var visualizerChoice: Visualizer
    private var intervalChoice: Double
    private var colorsChoice: ArtworkColors
    private let segmented = NSSegmentedControl(labels: ModernAppearance.allCases.map(\.title), trackingMode: .selectOne,
                                               target: nil, action: nil)
    private var swatches: [TintSwatch] = []
    private let tintName = makeLabel(size: 11, weight: .medium, color: .secondaryLabelColor)
    private(set) var tiles: [VisualizerTile] = []
    private let visualizerName = makeLabel(size: 11, weight: .medium, color: .secondaryLabelColor)
    let intervals = NSSegmentedControl(labels: ModernPlayerState.visualizerIntervals.map(AppearancePopover.shortInterval),
                                       trackingMode: .selectOne, target: nil, action: nil)
    let backgrounds = NSSegmentedControl(labels: ArtworkColors.allCases.map(\.title), trackingMode: .selectOne, target: nil,
                                         action: nil)

    init(appearance: ModernAppearance, tint: ModernTint, visualizer: Visualizer = .default,
         interval: Double = ModernPlayerState.defaultVisualizerInterval, colors: ArtworkColors = .default) {
        appearanceChoice = appearance
        tintChoice = tint
        visualizerChoice = visualizer
        intervalChoice = interval
        colorsChoice = colors
        super.init(nibName: nil, bundle: nil)
    }

    /// `10s`, `1m`.
    nonisolated static func shortInterval(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s % 60 == 0 ? "\(s / 60)m" : "\(s)s"
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
        y += (size + 10) * 2 + 4
        y = addVisualizerSection(to: root, y: y, width: width, padding: p)
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

    /// The scenes as a grid of tiles, how often Rotate moves on, and the artwork's colours. Returns the next y.
    private func addVisualizerSection(to root: NSView, y start: CGFloat, width: CGFloat, padding p: CGFloat) -> CGFloat {
        var y = start
        let title = makeLabel("Visualizer", size: 11, weight: .semibold, color: .secondaryLabelColor)
        title.frame = CGRect(x: p, y: y, width: 100, height: 15)
        root.addSubview(title)
        visualizerName.alignment = .right
        visualizerName.frame = CGRect(x: width - p - 140, y: y, width: 140, height: 15)
        root.addSubview(visualizerName)
        y += 22
        let columns = 7
        let tileHeight: CGFloat = 30, spacing: CGFloat = 5
        let tileWidth = (width - p * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        for (i, mode) in Visualizer.allCases.enumerated() {
            let tile = VisualizerTile(mode: mode)
            tile.frame = CGRect(x: p + CGFloat(i % columns) * (tileWidth + spacing), y: y + CGFloat(i / columns) * (tileHeight + spacing),
                                width: tileWidth, height: tileHeight)
            tile.onPick = { [weak self] in self?.pick(mode) }
            root.addSubview(tile)
            tiles.append(tile)
        }
        let rows = (Visualizer.allCases.count + columns - 1) / columns
        y += CGFloat(rows) * (tileHeight + spacing) + 6
        /// A label beside its control, or (`below`) above it at full width.
        func row(_ label: String, _ control: NSSegmentedControl, action: Selector, below: Bool = false) {
            let name = makeLabel(label, size: 11, weight: .medium, color: .secondaryLabelColor)
            name.frame = CGRect(x: p, y: y + (below ? 0 : 4), width: 84, height: 15)
            root.addSubview(name)
            if below { y += 20 }
            control.target = self
            control.action = action
            control.segmentDistribution = .fillEqually
            control.controlSize = .small
            let x = below ? p : p + 86
            control.frame = CGRect(x: x, y: y, width: width - p - x, height: 22)
            root.addSubview(control)
            y += 30
        }
        row("Rotate every", intervals, action: #selector(intervalChanged(_:)))
        intervals.toolTip = "How long each scene shows while the visualizer rotates"
        row("Background", backgrounds, action: #selector(colorsChanged(_:)), below: true)
        for (i, colors) in ArtworkColors.allCases.enumerated() { backgrounds.setToolTip(colors.help, forSegment: i) }
        return y + 2
    }

    private func updateSelection() {
        for swatch in swatches { swatch.isSelected = swatch.tint == tintChoice }
        tintName.stringValue = tintChoice.title
        for tile in tiles {
            tile.tint = tintChoice
            tile.isSelected = tile.mode == visualizerChoice
        }
        visualizerName.stringValue = visualizerChoice.title
        intervals.selectedSegment = Self.nearestInterval(intervalChoice)
        backgrounds.selectedSegment = ArtworkColors.allCases.firstIndex(of: colorsChoice) ?? 0
    }

    /// The offered interval nearest `seconds`.
    nonisolated static func nearestInterval(_ seconds: Double) -> Int {
        let all = ModernPlayerState.visualizerIntervals
        return all.indices.min { abs(all[$0] - seconds) < abs(all[$1] - seconds) } ?? 0
    }

    private func pick(_ tint: ModernTint) {
        tintChoice = tint
        updateSelection()
        onEvent?(.setTint(tint))
    }

    /// Picks a visualiser as its tile would (tests).
    func pick(_ mode: Visualizer) {
        visualizerChoice = mode
        updateSelection()
        onEvent?(.setVisualizer(mode))
    }

    @objc private func intervalChanged(_ sender: NSSegmentedControl) {
        let all = ModernPlayerState.visualizerIntervals
        let seconds = all[min(max(sender.selectedSegment, 0), all.count - 1)]
        intervalChoice = seconds
        onEvent?(.setVisualizerInterval(seconds))
    }

    @objc private func colorsChanged(_ sender: NSSegmentedControl) {
        let all = ArtworkColors.allCases
        let colors = all[min(max(sender.selectedSegment, 0), all.count - 1)]
        colorsChoice = colors
        onEvent?(.setArtworkColors(colors))
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

/// One visualiser choice: its symbol on a rounded tile, filled with the tint when chosen.
final class VisualizerTile: NSView {
    let mode: ModernPlayerState.Visualizer
    var onPick: (() -> Void)?
    var isSelected = false { didSet { updateColors() } }
    var tint = ModernTint.default { didSet { updateColors() } }
    private let plate = StillLayer()
    private let icon = PassiveImageView()
    private var hovering = false { didSet { updateColors() } }
    private var trackingArea: NSTrackingArea?

    init(mode: ModernPlayerState.Visualizer) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        plate.cornerRadius = 8
        plate.cornerCurve = .continuous
        layer?.addSublayer(plate)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        icon.image = mode == .toast ? Self.toastIcon
            : (NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil))?.withSymbolConfiguration(config)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        toolTip = mode.title
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(mode.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The Dancing Toast's pixel slice with its face cut out, as a template image the size of the symbols (SF Symbols
    /// has no toast). One point a pixel.
    static let toastIcon: NSImage = {
        let sprite = ToastScene.sprite(width: 24, height: 26)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Bottom centre of the slice, between two pixel columns.
            let ox = 8, oy = 15
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            for row in sprite.rows {
                for col in sprite.columns where sprite[col, row] != 0 {
                    ctx.fill(CGRect(x: ox + col, y: oy + row, width: 1, height: 1))
                }
            }
            // Eyes and a smile, cut out.
            let eye = oy + sprite.crown + 4
            for (x, y) in [(-3, eye), (-3, eye + 1), (2, eye), (2, eye + 1), (-2, eye + 3), (1, eye + 3), (-1, eye + 4), (0, eye + 4)] {
                ctx.clear(CGRect(x: ox + x, y: y, width: 1, height: 1))
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The whole control takes the click, never the image inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01 else { return nil }
        return frame.contains(point) ? self : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        plate.frame = bounds
        icon.frame = bounds
        updateColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateColors() {
        let dark = effectiveAppearance.isDark
        let accent = dark ? tint.accent.dark : tint.accent.light
        if isSelected {
            plate.backgroundColor = accent.cgColor
            icon.contentTintColor = accent.contrast(with: .white) >= 2.2 ? .white : NSColor(white: 0.1, alpha: 1)
        } else {
            let wash = dark ? CGColor(gray: 1, alpha: hovering ? 0.16 : 0.08) : CGColor(gray: 0, alpha: hovering ? 0.1 : 0.05)
            plate.backgroundColor = wash
            icon.contentTintColor = .secondaryLabelColor
        }
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    /// Claimed, so the mouse-up comes here.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPick?()
        return true
    }
}
