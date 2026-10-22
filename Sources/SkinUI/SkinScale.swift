// SPDX-License-Identifier: GPL-3.0-or-later
// Uniform window scale (DESIGN §8.1): every window is its 1x skin frame drawn at 1, 2 or 3 points per skin pixel
// with nearest-neighbour filtering. Window origins and sizes stay on whole points, so on a 2x display a skin pixel
// is exactly 2, 4 or 6 device pixels and the picture is pixel-exact at every scale.

import CoreGraphics
import SkinKit

nonisolated public enum SkinScale {
    public static let allowed = [1, 2, 3]

    /// 2 on Retina (backing scale ≥ 2), else 1.
    public static func defaultScale(backingScaleFactor: CGFloat) -> Int {
        backingScaleFactor >= 2 ? 2 : 1
    }

    /// The nearest allowed scale.
    public static func clamp(_ scale: Int) -> Int {
        min(max(scale, allowed.first!), allowed.last!)
    }

    /// Window content size in points for a composer window at `scale`.
    public static func pointSize(_ kind: WindowKind, scale: Int) -> CGSize {
        CGSize(width: kind.size.width * scale, height: kind.size.height * scale)
    }

    /// Integer point size (docking geometry works in whole points).
    public static func intSize(_ kind: WindowKind, scale: Int) -> IntSize {
        IntSize(kind.size.width * scale, kind.size.height * scale)
    }

    /// A skin rect (top-left origin, y down) as a view rect in a flipped view (also top-left, y down).
    public static func viewRect(_ rect: IntRect, scale: Int) -> CGRect {
        CGRect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
    }

    /// A skin rect as a rect in an unflipped view of `viewHeight` points (bottom-left origin).
    public static func unflippedViewRect(_ rect: IntRect, scale: Int, viewHeight: CGFloat) -> CGRect {
        let r = viewRect(rect, scale: scale)
        return CGRect(x: r.minX, y: viewHeight - r.maxY, width: r.width, height: r.height)
    }

    /// A point in a flipped view → fractional skin pixels.
    public static func skinPoint(_ viewPoint: CGPoint, scale: Int) -> CGPoint {
        CGPoint(x: viewPoint.x / CGFloat(scale), y: viewPoint.y / CGFloat(scale))
    }

    /// The skin pixel containing a fractional skin point.
    public static func skinPixel(_ skinPoint: CGPoint) -> IntPoint {
        IntPoint(Int(skinPoint.x.rounded(.down)), Int(skinPoint.y.rounded(.down)))
    }

    /// Device pixels per skin pixel; ≥ 2 allows the Core Text overlay for titles the skin font cannot draw.
    public static func devicePixelsPerSkinPixel(scale: Int, backingScaleFactor: CGFloat) -> CGFloat {
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
