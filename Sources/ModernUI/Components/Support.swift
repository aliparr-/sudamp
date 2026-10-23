// SPDX-License-Identifier: GPL-3.0-or-later
// Small pieces every modern view uses: a top-left-origin view, layers that never animate by themselves, motion that
// honours Reduce Motion, and the shared metrics.

import AppKit
import QuartzCore

/// Top-left origin, like the layouts.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Text that never takes a click: it reaches the control or card under it. (A label inside a button would otherwise
/// be what AppKit's hit test finds, and swallow the mouse-down.)
final class PassiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An image that never takes a click (an NSImageView inside a button would swallow its mouse-downs).
final class PassiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A card's background: pressing it drags the window (WindowServer-driven, like a title bar), and the first click
/// works even while the app is in the background.
final class DragSurface: FlippedView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return super.mouseDown(with: event) }
        window.performDrag(with: event)
    }
}

/// A layer whose property changes never animate implicitly: every animation here is explicit.
nonisolated final class StillLayer: CALayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

nonisolated final class StillGradientLayer: CAGradientLayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

nonisolated final class StillShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

nonisolated final class StillTextLayer: CATextLayer {
    override func action(forKey event: String) -> (any CAAction)? { nil }
}

/// The modern window's geometry, in points.
nonisolated enum Metrics {
    static let cardWidth: CGFloat = 380
    static let cardRadius: CGFloat = 30
    static let padding: CGFloat = 16
    /// Between the cards.
    static let gap: CGFloat = 12
    /// Transparent space around the cards for their shadows (clicks there reach the windows below).
    static let margin: CGFloat = 34
    static let nowPlayingHeight: CGFloat = 262
    static let equalizerHeight: CGFloat = 216
    static let stationsHeight: CGFloat = 312
    static let artwork: CGFloat = 92
    /// Concentric corners: an inner shape's radius is the outer radius less its inset.
    static func concentric(inset: CGFloat) -> CGFloat { max(4, cardRadius - inset) }
}

enum Motion {
    /// The system's Reduce Motion setting: no drifting light, no scrolling titles, cross-fades instead of slides.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Apple's "smooth" spring feel as a cubic curve, for AppKit animations that can't take a spring.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static let easeInOut = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)

    /// A critically damped-ish spring for `keyPath`, from the presentation value to `to`.
    static func spring(_ keyPath: String, on layer: CALayer, to value: Any, damping: CGFloat = 16,
                       stiffness: CGFloat = 260, mass: CGFloat = 1) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
        guard !reduced else {
            layer.removeAnimation(forKey: keyPath)
            return
        }
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = value
        spring.damping = damping
        spring.stiffness = stiffness
        spring.mass = mass
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: keyPath)
    }

    /// A plain animation of `keyPath` from the presentation value.
    static func animate(_ keyPath: String, on layer: CALayer, to value: Any, duration: Double,
                        timing: CAMediaTimingFunction = easeOut) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
        guard !reduced || keyPath == "opacity", duration > 0 else {
            layer.removeAnimation(forKey: keyPath)
            return
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: keyPath)
    }

    /// A transform that scales by `s` around the centre of `bounds` (AppKit view layers have a (0, 0) anchor).
    static func scale(_ s: CGFloat, around bounds: CGRect) -> CATransform3D {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -c.x, -c.y, 0)
    }
}

extension NSView {
    /// The backing scale for crisp layer contents.
    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// A point in this view, in AppKit screen coordinates.
    func screenPoint(_ point: CGPoint) -> CGPoint {
        guard let window else { return .zero }
        return window.convertPoint(toScreen: convert(point, to: nil))
    }

    /// Where a menu anchored under this view opens: its bottom-left corner, 4 points below.
    var menuAnchorBelow: CGPoint {
        let bottom = isFlipped ? bounds.maxY + 4 : bounds.minY - 4
        return screenPoint(CGPoint(x: bounds.minX, y: bottom))
    }
}

extension CAKeyframeAnimation {
    /// Sets the keyframe values as a plain Objective-C array, built object by object and set by key. Anything assigned
    /// through `values` (a Swift array of numbers, even one of NSNumbers) reaches Core Animation as a lazily bridged
    /// `__SwiftDeferredNSArray` that boxes its elements on first read, and Core Animation reading one during a commit
    /// crashed on macOS 26.6 (EXC_BAD_ACCESS in __SwiftDeferredNSArray, from -[CAKeyframeAnimation
    /// CA_prepareRenderValue]); set by key, it gets an immutable __NSArrayI.
    func setKeyframes(_ numbers: [Double]) {
        let array = NSMutableArray(capacity: numbers.count)
        for n in numbers { array.add(NSNumber(value: n)) }
        setValue(array.copy(), forKey: "values")
    }

    /// The same for values that are objects already (NSValue points, NSArray gradient locations).
    func setKeyframes(objects: [AnyObject]) {
        let array = NSMutableArray(capacity: objects.count)
        for object in objects { array.add(object) }
        setValue(array.copy(), forKey: "values")
    }
}

/// An immutable Objective-C array of numbers (a keyframe that is itself a list, like gradient locations).
func numberArray(_ numbers: [Double]) -> NSArray {
    let array = NSMutableArray(capacity: numbers.count)
    for n in numbers { array.add(NSNumber(value: n)) }
    return array.copy() as! NSArray
}

/// A label that is just text: no bezel, no selection, one line, truncating.
func makeLabel(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
               monospacedDigits: Bool = false) -> NSTextField {
    let label = PassiveLabel(labelWithString: text)
    label.font = monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
        : .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    label.allowsDefaultTighteningForTruncation = true
    return label
}

/// A rounded rectangle path (continuous corners where available).
func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, rect.width / 2, rect.height / 2)
    return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// A tiny film-grain tile, made once: a few percent of noise keeps large gradients from banding and gives them the
/// texture of printed artwork.
@MainActor let grainImage: CGImage? = {
    let size = 96
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for i in 0..<(size * size) {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        let v = UInt8(truncatingIfNeeded: seed >> 56)
        pixels[i * 4] = v
        pixels[i * 4 + 1] = v
        pixels[i * 4 + 2] = v
        pixels[i * 4 + 3] = 255
    }
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}()
