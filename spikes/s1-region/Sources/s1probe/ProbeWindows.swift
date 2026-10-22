// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: the shaped (borderless, clear) window under test and the ordinary window beneath it.
import AppKit
import RegionRaster

/// The three states `ignoresMouseEvents` can be in. "unset" (never assigned) is the one that
/// matters: the hypothesis is that WindowServer then lets clicks on alpha-0 pixels through.
enum IgnoresSetting: String, CaseIterable, Codable {
    case unset
    case explicitFalse = "false"
    case explicitTrue = "true"
}

/// Who handled a click, for logs and JSON.
enum ClickTarget: String, Codable {
    case shaped, lower, none
}

final class ShapedWindow: NSWindow {
    /// The app's SkinWindow returns true (DESIGN §8.1). The headless measurement turns it off so a
    /// synthesised click can't make the probe key and take focus from whatever the owner is doing.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { allowsKey }
}

/// Shows the mask at 1x skin pixels scaled with nearest-neighbour filtering, as the app will
/// (DESIGN §8.1: the frame becomes `layer.contents` with `.nearest`).
final class ShapedView: NSView {
    private(set) var mask: Mask
    /// When on, `hitTest` answers nil over alpha-0 pixels (the "hitTest override" variant).
    var hitTestOverride = false
    /// Manual mode drags the window from its opaque parts so it can be moved over other apps.
    var dragsWindow = false
    var onMouseDown: ((_ x: Int, _ y: Int, _ opaque: Bool) -> Void)?

    init(mask: Mask) {
        self.mask = mask
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: CGFloat(mask.width) * ProbeShape.scale, height: CGFloat(mask.height) * ProbeShape.scale
        ))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // skin coordinates: y grows downwards
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = ProbeShape.image(for: mask)
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.isOpaque = false
    }

    func setMask(_ newMask: Mask) {
        mask = newMask
        needsDisplay = true
    }

    func skinPixel(_ local: NSPoint) -> (x: Int, y: Int) {
        (Int((local.x / ProbeShape.scale).rounded(.down)), Int((local.y / ProbeShape.scale).rounded(.down)))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hitTestOverride else { return super.hitTest(point) }
        let p = skinPixel(convert(point, from: superview))
        return mask[p.x, p.y] ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = skinPixel(convert(event.locationInWindow, from: nil))
        onMouseDown?(p.x, p.y, mask[p.x, p.y])
        if dragsWindow { window?.performDrag(with: event) }
    }
}

/// The ordinary window below: diagonal stripes so the notch visibly shows it, and a click logger.
final class LowerView: NSView {
    var onMouseDown: ((_ point: NSPoint) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        bounds.fill()
        NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.2, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 6
        var x = -bounds.height
        while x < bounds.width {
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x + bounds.height, y: bounds.height))
            x += 24
        }
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(convert(event.locationInWindow, from: nil))
    }
}

enum ProbeWindows {
    /// A borderless, non-opaque, shadowed window showing `mask`, top-left corner at `topLeft` (Cocoa
    /// screen coordinates). `ignores` is applied exactly once, at creation, because "unset" can't be
    /// restored after assigning either value.
    static func makeShaped(
        mask: Mask, topLeft: NSPoint, ignores: IgnoresSetting, hitTestOverride: Bool
    ) -> (ShapedWindow, ShapedView) {
        let view = ShapedView(mask: mask)
        view.hitTestOverride = hitTestOverride
        let window = ShapedWindow(
            contentRect: NSRect(x: topLeft.x, y: topLeft.y - view.frame.height, width: view.frame.width, height: view.frame.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating  // stays above the lower window even when that one is clicked
        switch ignores {
        case .unset: break
        case .explicitFalse: window.ignoresMouseEvents = false
        case .explicitTrue: window.ignoresMouseEvents = true
        }
        window.contentView = view
        return (window, view)
    }

    static func makeLower(frame: NSRect, title: String) -> (NSWindow, LowerView) {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        let view = LowerView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        return (window, view)
    }

    /// Centre of skin pixel (x, y) in Cocoa screen coordinates (origin bottom-left of the main display).
    static func screenPoint(_ spot: ProbeShape.Spot, in window: NSWindow) -> NSPoint {
        let f = window.frame
        return NSPoint(
            x: f.minX + (CGFloat(spot.x) + 0.5) * ProbeShape.scale,
            y: f.maxY - (CGFloat(spot.y) + 0.5) * ProbeShape.scale
        )
    }
}
