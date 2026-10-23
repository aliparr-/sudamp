// SPDX-License-Identifier: GPL-3.0-or-later
// Uniform window scale (DESIGN §8.1): every window is its 1x skin frame drawn at `scale` points per skin pixel
// with nearest-neighbour filtering. Window origins and sizes stay on whole points. At 1x, 2x and 3x a skin pixel
// is a whole number of points, so on a 2x display it is exactly 2, 4 or 6 device pixels and the picture is
// pixel-exact. The in-between scales (1.2x, 1.5x, 2.5x) round each window to whole points and stretch the 1x
// frame over it, so some skin pixels are a device pixel wider or taller than others.

import CoreGraphics
import SkinKit

nonisolated public enum SkinScale {
    /// The scales on offer, smallest first.
    public static let allowed: [Double] = [1, 1.2, 1.5, 2, 2.5, 3]

    /// 2 on Retina (backing scale ≥ 2), else 1.
    public static func defaultScale(backingScaleFactor: CGFloat) -> Double {
        backingScaleFactor >= 2 ? 2 : 1
    }

    /// The nearest allowed scale (1x for NaN).
    public static func clamp(_ scale: Double) -> Double {
        guard !scale.isNaN else { return allowed[0] }
        let bounded = min(max(scale, allowed.first!), allowed.last!)
        return allowed.min { abs($0 - bounded) < abs($1 - bounded) }!
    }

    /// A whole number of points per skin pixel (1x, 2x, 3x).
    public static func isWhole(_ scale: Double) -> Bool { scale == scale.rounded() }

    /// "1x", "1.5x".
    public static func label(_ scale: Double) -> String {
        isWhole(scale) ? "\(Int(scale))x" : "\(scale)x"
    }

    /// Window content size in points for a composer window at `scale`, rounded to whole points.
    public static func pointSize(_ kind: WindowKind, scale: Double) -> CGSize {
        let size = intSize(kind, scale: scale)
        return CGSize(width: size.width, height: size.height)
    }

    /// Integer point size (docking geometry works in whole points).
    public static func intSize(_ kind: WindowKind, scale: Double) -> IntSize {
        IntSize(Int((Double(kind.size.width) * scale).rounded()), Int((Double(kind.size.height) * scale).rounded()))
    }

    /// Points per skin pixel across and down a window: its whole-point size over its skin size. Exactly `scale` at
    /// whole scales; at the others the window's rounding is spread over it, as the base layer stretches its image.
    public static func pointsPerSkinPixel(_ kind: WindowKind, scale: Double) -> (x: CGFloat, y: CGFloat) {
        let size = intSize(kind, scale: scale)
        return (CGFloat(size.width) / CGFloat(kind.size.width), CGFloat(size.height) / CGFloat(kind.size.height))
    }

    /// A skin rect (top-left origin, y down) as a view rect in a flipped view (also top-left, y down) of a `kind`
    /// window, lined up with the base layer's pixels.
    public static func viewRect(_ rect: IntRect, in kind: WindowKind, scale: Double) -> CGRect {
        let f = pointsPerSkinPixel(kind, scale: scale)
        return CGRect(x: CGFloat(rect.x) * f.x, y: CGFloat(rect.y) * f.y,
                      width: CGFloat(rect.width) * f.x, height: CGFloat(rect.height) * f.y)
    }

    /// A skin rect as a rect in an unflipped view of `viewHeight` points (bottom-left origin).
    public static func unflippedViewRect(_ rect: IntRect, in kind: WindowKind, scale: Double,
                                         viewHeight: CGFloat) -> CGRect {
        let r = viewRect(rect, in: kind, scale: scale)
        return CGRect(x: r.minX, y: viewHeight - r.maxY, width: r.width, height: r.height)
    }

    /// A point in a flipped view of a `kind` window → fractional skin pixels.
    public static func skinPoint(_ viewPoint: CGPoint, in kind: WindowKind, scale: Double) -> CGPoint {
        let f = pointsPerSkinPixel(kind, scale: scale)
        return CGPoint(x: viewPoint.x / f.x, y: viewPoint.y / f.y)
    }

    /// The skin pixel containing a fractional skin point.
    public static func skinPixel(_ skinPoint: CGPoint) -> IntPoint {
        IntPoint(Int(skinPoint.x.rounded(.down)), Int(skinPoint.y.rounded(.down)))
    }

    /// Device pixels per skin pixel; ≥ 2 allows the Core Text overlay for titles the skin font cannot draw.
    public static func devicePixelsPerSkinPixel(scale: Double, backingScaleFactor: CGFloat) -> CGFloat {
        CGFloat(scale) * backingScaleFactor
    }
}

/// A slider's travel in skin pixels: the thumb's leading edge runs from `origin` to `origin + travel`.
/// Matches the composer's thumb placement (SkinKit Layout and WindowComposer).
nonisolated public struct SliderTrack: Equatable, Sendable {
    public enum Axis: Sendable, Equatable { case horizontal, vertical }

    public var axis: Axis
    public var origin: Double
    public var travel: Double
    public var thumbLength: Double

    public init(axis: Axis, origin: Double, travel: Double, thumbLength: Double) {
        self.axis = axis
        self.origin = origin
        self.travel = travel
        self.thumbLength = thumbLength
    }

    /// The coordinate along the slider's axis.
    public func coordinate(_ point: CGPoint) -> Double {
        Double(axis == .horizontal ? point.x : point.y)
    }

    /// 0...1 for a thumb whose leading edge is at `leading`.
    public func fraction(leading: Double) -> Double {
        guard travel > 0, leading.isFinite else { return 0 }
        return min(max((leading - origin) / travel, 0), 1)
    }

    public func leading(fraction: Double) -> Double {
        origin + travel * min(max(fraction.isNaN ? 0 : fraction, 0), 1)
    }

    /// Where the pointer holds the thumb: its own offset when pressed on the thumb, else the thumb's middle
    /// (the thumb jumps to the pointer, like an HTML range input in Webamp).
    public func grabOffset(at coordinate: Double, currentFraction: Double) -> Double {
        let lead = leading(fraction: currentFraction)
        if coordinate >= lead, coordinate < lead + thumbLength { return coordinate - lead }
        return thumbLength / 2
    }

    public func fraction(at coordinate: Double, grab: Double) -> Double {
        fraction(leading: coordinate - grab)
    }

    /// The slider track for a control in a window, if it is a slider there.
    public static func track(for control: Control, in kind: WindowKind) -> SliderTrack? {
        switch (kind, control) {
        case (.main, .volume):
            return .init(axis: .horizontal, origin: Double(MainLayout.volume.x), travel: Double(MainLayout.volumeTravel),
                         thumbLength: Double(MainLayout.sliderThumb.width))
        case (.main, .balance):
            return .init(axis: .horizontal, origin: Double(MainLayout.balance.x), travel: Double(MainLayout.balanceTravel),
                         thumbLength: Double(MainLayout.sliderThumb.width))
        case (.main, .position):
            return .init(axis: .horizontal, origin: Double(MainLayout.position.x), travel: Double(MainLayout.positionTravel),
                         thumbLength: Double(MainLayout.positionThumb.width))
        case (.shade, .position):
            return .init(axis: .horizontal, origin: Double(ShadeLayout.position.x), travel: Double(ShadeLayout.positionTravel),
                         thumbLength: Double(ShadeLayout.positionThumb.width))
        case (.eqShade, .volume):
            return .init(axis: .horizontal, origin: Double(EQShadeLayout.volume.x), travel: Double(EQShadeLayout.volumeTravel),
                         thumbLength: Double(EQShadeLayout.thumb.width))
        case (.eqShade, .balance):
            return .init(axis: .horizontal, origin: Double(EQShadeLayout.balance.x), travel: Double(EQShadeLayout.balanceTravel),
                         thumbLength: Double(EQShadeLayout.thumb.width))
        case (.eq, .preamp):
            return .init(axis: .vertical, origin: Double(EQLayout.preamp.y), travel: Double(EQLayout.thumbTravel),
                         thumbLength: Double(EQLayout.thumb.height))
        case (.eq, let band) where Control.bands.contains(band):
            return .init(axis: .vertical, origin: Double(EQLayout.band(0).y), travel: Double(EQLayout.thumbTravel),
                         thumbLength: Double(EQLayout.thumb.height))
        case (.playlist, .playlistScrollbar):
            return .init(axis: .vertical, origin: Double(PlaylistLayout.scrollTrack.y), travel: Double(PlaylistLayout.scrollTravel),
                         thumbLength: Double(PlaylistLayout.scrollThumb.height))
        default:
            return nil
        }
    }
}

/// Value conversions between slider fractions and app units.
nonisolated public enum SliderValues {
    /// Webamp: balance within ±25 % of centre clips to the centre.
    public static let balanceCentreSnap = 0.25

    public static func balance(fraction: Double) -> Double {
        let b = min(max(fraction * 2 - 1, -1), 1)
        return abs(b) < balanceCentreSnap ? 0 : b
    }

    public static func balanceFraction(_ balance: Double) -> Double {
        (min(max(balance, -1), 1) + 1) / 2
    }

    /// EQ sliders run top (+12 dB) to bottom (-12 dB); the fraction is from the top.
    public static func decibels(eqFraction: Double) -> Double {
        EQSliderGeometry.decibels(for: (1 - min(max(eqFraction, 0), 1)) * 100)
    }

    public static func eqFraction(decibels: Double) -> Double {
        1 - EQSliderGeometry.value(forDecibels: decibels) / 100
    }
}
