// SPDX-License-Identifier: GPL-3.0-or-later
// The Equalizer card: a header (title, presets, reset, on/off) over the preamp and ten band sliders. Behind the band
// sliders a smooth response curve runs through the thumbs, glowing in the tint and filled down to the 0 dB line, so
// the shape of the EQ reads at a glance. Every slider catches at 0 dB with a haptic tick; double-click resets one.

import AppKit
import QuartzCore

/// The response curve's shape, pure and unit-tested.
nonisolated enum EQCurve {
    /// A Catmull-Rom curve through `points`, extended flat to `minX` and `maxX`.
    static func path(through points: [CGPoint], minX: CGFloat, maxX: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: minX, y: first.y))
        path.addLine(to: first)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.addLine(to: CGPoint(x: maxX, y: last.y))
        return path
    }

    /// The curve closed down (or up) to the 0 dB line at `baseline`, for the fill.
    static func fillPath(through points: [CGPoint], minX: CGFloat, maxX: CGFloat, baseline: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addPath(Self.path(through: points, minX: minX, maxX: maxX))
        path.addLine(to: CGPoint(x: maxX, y: baseline))
        path.addLine(to: CGPoint(x: minX, y: baseline))
        path.closeSubpath()
        return path
    }

    /// dB (-12...12) → slider value 0...1.
    static func value(decibels: Double) -> Double {
        let r = ModernPlayerState.Equalizer.range
        return (min(max(decibels.isFinite ? decibels : 0, r.lowerBound), r.upperBound) - r.lowerBound) / (r.upperBound - r.lowerBound)
    }

    /// Slider value 0...1 → dB, rounded to a tenth.
    static func decibels(value: Double) -> Double {
        let r = ModernPlayerState.Equalizer.range
        return ((r.lowerBound + min(max(value, 0), 1) * (r.upperBound - r.lowerBound)) * 10).rounded() / 10
    }

    static func label(_ db: Double) -> String {
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0 dB" }
        return (rounded > 0 ? "+" : "−") + String(format: "%.1f dB", abs(rounded))
    }
}

final class EqualizerCard: GlassCard {
    var onEvent: ((ModernEvent) -> Void)?

    let titleLabel = makeLabel("Equalizer", size: 13, weight: .semibold)
    let presetsButton = CapsuleButton(label: "Presets")
    let resetButton = GlyphButton(symbol: "arrow.counterclockwise", pointSize: 12, weight: .semibold, label: "Reset to Flat")
    let toggle = ModernSwitch(label: "Equalizer On")
    let preamp = ModernSlider(axis: .vertical, label: "Preamp")
    let bands: [ModernSlider]
    private let scaleLabels = ["+12", "0", "−12"].map { makeLabel($0, size: 9, weight: .medium, color: .tertiaryLabelColor,
                                                                    monospacedDigits: true) }
    private let bandLabels: [NSTextField]
    private let preampLabel = makeLabel("PRE", size: 9, weight: .semibold, color: .tertiaryLabelColor)
    private let curveHost = FlippedView()
    private let curve = StillShapeLayer()
    private let curveFill = StillGradientLayer()
    private let curveFillMask = StillShapeLayer()
    private let zeroLine = StillShapeLayer()
    private let divider = StillLayer()
    private var palette: ModernPalette?
    private(set) var equalizer = ModernPlayerState.Equalizer()

    override init(frame frameRect: NSRect) {
        bands = (0..<ModernPlayerState.Equalizer.bandCount).map { i in
            ModernSlider(axis: .vertical, label: "\(ModernPlayerState.Equalizer.bandLabels[i]) Hz")
        }
        bandLabels = ModernPlayerState.Equalizer.bandLabels.map { makeLabel($0, size: 9, weight: .medium, color: .tertiaryLabelColor) }
        super.init(frame: frameRect)
        naturalHeight = Metrics.equalizerHeight
        presetsButton.style = .neutral
        presetsButton.titleFont = .systemFont(ofSize: 11.5, weight: .semibold)
        presetsButton.onPress = { [weak self] in
            guard let self else { return }
            self.onEvent?(.presetsMenu(self.presetsButton.menuAnchorBelow))
        }
        resetButton.tone = .secondary
        resetButton.onPress = { [weak self] in self?.onEvent?(.eqReset) }
        toggle.onToggle = { [weak self] on in self?.onEvent?(.eqEnabled(on)) }
        curveHost.wantsLayer = true
        curveFill.startPoint = CGPoint(x: 0.5, y: 0)
        curveFill.endPoint = CGPoint(x: 0.5, y: 1)
        curveFill.mask = curveFillMask
        curveHost.layer?.addSublayer(zeroLine)
        curveHost.layer?.addSublayer(curveFill)
        curve.fillColor = nil
        curve.lineWidth = 2
        curve.lineCap = .round
        curve.lineJoin = .round
        curve.shadowOffset = .zero
        curve.shadowRadius = 5
        curveHost.layer?.addSublayer(curve)
        zeroLine.fillColor = nil
        zeroLine.lineWidth = 1
        zeroLine.lineDashPattern = [2, 3]
        for label in bandLabels { label.alignment = .center }
        preampLabel.alignment = .center
        for label in scaleLabels { label.alignment = .right }
        content.addSubview(curveHost)
        for view: NSView in [titleLabel, presetsButton, resetButton, toggle, preamp, preampLabel] + bands + bandLabels + scaleLabels {
            content.addSubview(view)
        }
        content.layer?.addSublayer(divider)
        for (i, slider) in ([preamp] + bands).enumerated() {
            slider.detents = [0.5]
            slider.fillOrigin = 0.5
            slider.trackThickness = 4
            slider.knobDiameter = 14
            slider.step = 1.0 / 24
            slider.accessibilityValueText = { EQCurve.label(EQCurve.decibels(value: $0)) }
            slider.onChange = { [weak self] value, _ in self?.sliderMoved(i - 1, value: value) }
        }
        apply(equalizer: equalizer, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func apply(_ palette: ModernPalette) {
        super.apply(palette)
        self.palette = palette
        presetsButton.apply(palette)
        resetButton.apply(palette)
        toggle.apply(palette)
        for slider in [preamp] + bands { slider.apply(palette) }
        divider.backgroundColor = palette.separator
        zeroLine.strokeColor = palette.separator
        applyCurveColors()
    }

    private func applyCurveColors() {
        guard let palette else { return }
        let on = equalizer.enabled
        let stroke = on ? palette.accent.cgColor : (palette.isDark ? CGColor(gray: 1, alpha: 0.35) : CGColor(gray: 0, alpha: 0.28))
        curve.strokeColor = stroke
        curve.shadowColor = on ? palette.accent.cgColor : CGColor(gray: 0, alpha: 0)
        curve.shadowOpacity = on ? (palette.isDark ? 0.8 : 0.5) : 0
        let fillAlpha = on ? (palette.isDark ? 0.3 : 0.22) : 0.08
        let base = on ? palette.accent : (palette.isDark ? RGB.white : RGB.black)
        curveFill.colors = [base.cgColor(alpha: fillAlpha), base.cgColor(alpha: fillAlpha * 0.15), base.cgColor(alpha: fillAlpha)]
        curveFill.locations = [0, 0.5, 1]
    }

    // MARK: State

    func apply(equalizer new: ModernPlayerState.Equalizer, force: Bool = false) {
        let old = equalizer
        equalizer = new
        toggle.isOn = new.enabled
        presetsButton.title = new.preset ?? "Presets"
        resetButton.isEnabled = !new.isFlat
        if !preamp.isDragging { preamp.value = EQCurve.value(decibels: new.preamp) }
        for (i, slider) in bands.enumerated() where !slider.isDragging {
            slider.value = EQCurve.value(decibels: i < new.bands.count ? new.bands[i] : 0)
        }
        for slider in [preamp] + bands { slider.muted = !new.enabled }
        if force || old.enabled != new.enabled { applyCurveColors() }
        if force || old != new { needsLayout = true }
    }

    private func sliderMoved(_ index: Int, value: Double) {
        let db = EQCurve.decibels(value: value)
        if index < 0 {
            onEvent?(.preamp(db))
        } else {
            onEvent?(.eqBand(index, db))
            updateCurve()
        }
    }

    // MARK: Layout

    private var sliderTop: CGFloat { 54 }
    private var sliderHeight: CGFloat { naturalHeight - sliderTop - 36 }

    override func layout() {
        super.layout()
        let w = bounds.width
        let p = Metrics.padding
        titleLabel.frame = CGRect(x: p + 2, y: p + 3, width: 120, height: 18)
        let toggleSize = ModernSwitch.size
        toggle.frame = CGRect(x: w - p - toggleSize.width, y: p + 12 - toggleSize.height / 2, width: toggleSize.width,
                              height: toggleSize.height)
        resetButton.frame = CGRect(x: toggle.frame.minX - 8 - 26, y: p - 1, width: 26, height: 26)
        let presetsWidth = min(presetsButton.fittingWidth, 160)
        presetsButton.frame = CGRect(x: resetButton.frame.minX - 4 - presetsWidth, y: p - 1, width: presetsWidth, height: 26)

        let top = sliderTop
        let height = sliderHeight
        let sliderWidth: CGFloat = 22
        // Scale labels, aligned with the knob travel (+12 at the top, 0 in the middle, -12 at the bottom).
        let knob: CGFloat = 14
        let travelTop = top + knob / 2, travelBottom = top + height - knob / 2
        for (label, y) in zip(scaleLabels, [travelTop, (travelTop + travelBottom) / 2, travelBottom]) {
            label.frame = CGRect(x: p - 4, y: y - 6, width: 24, height: 12)
        }
        let preampX = p + 26
        preamp.frame = CGRect(x: preampX, y: top, width: sliderWidth, height: height)
        preampLabel.frame = CGRect(x: preampX - 8, y: top + height + 8, width: sliderWidth + 16, height: 12)
        divider.frame = CGRect(x: preampX + sliderWidth + 10, y: top + 6, width: 1, height: height - 12)
        let bandsStart = preampX + sliderWidth + 20
        let bandsEnd = w - p
        let slot = (bandsEnd - bandsStart) / CGFloat(bands.count)
        for (i, slider) in bands.enumerated() {
            let x = bandsStart + slot * CGFloat(i) + (slot - sliderWidth) / 2
            slider.frame = CGRect(x: x, y: top, width: sliderWidth, height: height)
            bandLabels[i].frame = CGRect(x: x - 8, y: top + height + 8, width: sliderWidth + 16, height: 12)
        }
        curveHost.frame = CGRect(x: bandsStart, y: top, width: bandsEnd - bandsStart, height: height)
        curve.frame = curveHost.bounds
        curveFill.frame = curveHost.bounds
        curveFillMask.frame = curveHost.bounds
        zeroLine.frame = curveHost.bounds
        let zero = CGMutablePath()
        let mid = curveHost.bounds.midY
        zero.move(to: CGPoint(x: 0, y: mid))
        zero.addLine(to: CGPoint(x: curveHost.bounds.width, y: mid))
        zeroLine.path = zero
        updateCurve()
    }

    private func updateCurve() {
        let host = curveHost.bounds
        guard host.width > 0 else { return }
        let knob: CGFloat = 14
        let travelTop = knob / 2, travelBottom = host.height - knob / 2
        let points = bands.map { slider -> CGPoint in
            let x = slider.frame.midX - curveHost.frame.minX
            let y = SliderMath.position(of: slider.value, start: travelBottom, end: travelTop)
            return CGPoint(x: x, y: y)
        }
        curve.path = EQCurve.path(through: points, minX: 0, maxX: host.width)
        curveFillMask.path = EQCurve.fillPath(through: points, minX: 0, maxX: host.width, baseline: host.midY)
    }

    static var preferredHeight: CGFloat { Metrics.equalizerHeight }
}
