// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: `s1probe measure`, a headless run that needs no permissions and takes no focus.
//
// 1. WindowServer routing: `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)` is documented as
//    "the frontmost window that would be hit by a mouseDown at the screen location", so it asks the
//    WindowServer the click-through question directly, for each `ignoresMouseEvents` state. Windows
//    stacked above the probe (another app's overlay, the lock-screen shield) are excluded through the
//    API's own `belowWindowWithWindowNumber` argument, so the answer is about our windows only.
// 2. In-process dispatch: synthesised NSEvents sent to the shaped window show what a `hitTest`
//    override changes once a click has already been routed to us.
// 3. Shadow: captures our own window (shadow included) before and after a shape change and after
//    `invalidateShadow()`, and samples shadow alpha below the legs vs below the notch.
import AppKit
import RegionRaster

struct HitResult: Codable {
    let spot: String
    let maskOpaque: Bool
    let windowServerTarget: ClickTarget
    let otherWindow: String?
}

struct RoutingResult: Codable {
    let ignores: IgnoresSetting
    /// What the `ignoresMouseEvents` getter reports: it can't tell "unset" from "false".
    let getterValue: Bool
    /// How many on-screen windows were stacked above the probe and excluded from the queries.
    let windowsAboveProbe: Int
    /// The plain query (nothing excluded) at the notch spot, for the record.
    let rawTopmostAtNotch: String
    let hits: [HitResult]
    let outsideShapedInsideLower: ClickTarget
    /// The notch spot again with the lower window ordered out: does a window that isn't ours get it?
    let notchWithLowerHidden: String
}

struct DispatchResult: Codable {
    let hitTestOverride: Bool
    let spot: String
    let maskOpaque: Bool
    let viewGotMouseDown: Bool
    let windowServerTarget: ClickTarget
}

struct ShadowSample: Codable {
    let label: String
    let captured: Bool
    let imageSize: [Int]
    /// Alpha (0…255) of the capture at named skin-pixel spots; -1 = outside the capture.
    let alpha: [String: Int]
    /// Alpha along the row 3 skin px below the window's bottom edge, x = -15…290 step 5.
    let rowBelowBottom: [Int]
    /// Alpha down the notch at x = 108, y = 30…130 step 4 (notch top edge at y = 40, bottom at 116).
    let notchColumn: [Int]
}

/// One live window (ignoresMouseEvents unset) whose mask changes at run time, as on a skin switch
/// or shade toggle: does WindowServer's hit shape follow the new alpha?
struct ShapeChangeStep: Codable {
    let step: String
    let notchSpotTarget: ClickTarget
    let bodySpotTarget: ClickTarget
}

struct MeasureReport: Codable {
    let permissions: Permissions
    let screenLocked: Bool
    let backingScale: Double
    let routing: [RoutingResult]
    let shapeChange: [ShapeChangeStep]
    let dispatch: [DispatchResult]
    let shadow: [ShadowSample]
}

enum Measure {
    static let margin: CGFloat = 40

    static func run(pngDir: String?) -> MeasureReport {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no Dock icon, never activated: the owner keeps focus
        app.finishLaunching()
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let topLeft = NSPoint(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.maxY - 120)
        let notched = ProbeShape.mask(ProbeShape.notchedRegion)
        let size = NSSize(width: CGFloat(notched.width) * ProbeShape.scale, height: CGFloat(notched.height) * ProbeShape.scale)
        let lowerFrame = NSRect(x: topLeft.x - margin, y: topLeft.y - size.height - margin,
                                width: size.width + 2 * margin, height: size.height + 2 * margin)

        let routing = IgnoresSetting.allCases.map { routingResult(ignores: $0, mask: notched, topLeft: topLeft, lowerFrame: lowerFrame) }
        let shapeChange = shapeChangeSteps(notched: notched, topLeft: topLeft, lowerFrame: lowerFrame)
        let dispatch = [false, true].flatMap { dispatchResults(hitTestOverride: $0, mask: notched, topLeft: topLeft) }
        let shadow = shadowSamples(notched: notched, topLeft: topLeft, pngDir: pngDir)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return MeasureReport(permissions: .current(), screenLocked: (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false,
                             backingScale: Double(screen.backingScaleFactor),
                             routing: routing, shapeChange: shapeChange, dispatch: dispatch, shadow: shadow)
    }

    private static func shapeChangeSteps(notched: Mask, topLeft: NSPoint, lowerFrame: NSRect) -> [ShapeChangeStep] {
        let full = ProbeShape.mask(ProbeShape.fullRegion)
        let (lower, _) = ProbeWindows.makeLower(frame: lowerFrame, title: "S1 lower (shape change)")
        lower.level = .floating
        lower.orderFrontRegardless()
        let (shaped, view) = ProbeWindows.makeShaped(mask: full, topLeft: topLeft, ignores: .unset, hitTestOverride: false)
        shaped.allowsKey = false
        shaped.orderFrontRegardless()
        let notch = ProbeShape.clickSpots.first { $0.name == "notchTransparent" }!
        let body = ProbeShape.clickSpots.first { $0.name == "bodyOpaque" }!
        func step(_ name: String) -> ShapeChangeStep {
            pump(0.6)
            return ShapeChangeStep(
                step: name,
                notchSpotTarget: target(hitWindow(at: ProbeWindows.screenPoint(notch, in: shaped), under: shaped), shaped: shaped, lower: lower),
                bodySpotTarget: target(hitWindow(at: ProbeWindows.screenPoint(body, in: shaped), under: shaped), shaped: shaped, lower: lower)
            )
        }
        var steps = [step("1-created-full")]
        view.setMask(notched)
        steps.append(step("2-switched-to-notched"))
        view.setMask(full)
        steps.append(step("3-switched-back-to-full"))
        view.setMask(notched)
        shaped.invalidateShadow()
        steps.append(step("4-notched-again-plus-invalidateShadow"))
        shaped.close()
        lower.close()
        pump(0.2)
        return steps
    }

    /// On-screen windows stacked above `window`, front to back.
    private static func windowsAbove(_ window: NSWindow) -> [Int] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]
        return (info ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
    }

    /// WindowServer's answer to "which window would a mouseDown here hit?", ignoring every window
    /// stacked above `probe` (the API excludes the given window and all windows above it).
    private static func hitWindow(at point: NSPoint, under probe: NSWindow) -> Int {
        NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: windowsAbove(probe).last ?? 0)
    }

    private static func target(_ number: Int, shaped: NSWindow, lower: NSWindow?) -> ClickTarget {
        if number == shaped.windowNumber { return .shaped }
        if let lower, number == lower.windowNumber { return .lower }
        return .none
    }

    private static func routingResult(ignores: IgnoresSetting, mask: Mask, topLeft: NSPoint, lowerFrame: NSRect) -> RoutingResult {
        let (lower, _) = ProbeWindows.makeLower(frame: lowerFrame, title: "S1 lower (measure)")
        lower.level = .floating
        lower.orderFrontRegardless()
        let (shaped, _) = ProbeWindows.makeShaped(mask: mask, topLeft: topLeft, ignores: ignores, hitTestOverride: false)
        shaped.allowsKey = false
        shaped.orderFrontRegardless()
        pump(0.7)

        let hits = ProbeShape.clickSpots.map { spot -> HitResult in
            let n = hitWindow(at: ProbeWindows.screenPoint(spot, in: shaped), under: shaped)
            let t = target(n, shaped: shaped, lower: lower)
            return HitResult(spot: spot.name, maskOpaque: mask[spot.x, spot.y], windowServerTarget: t,
                             otherWindow: t == .none ? windowOwner(n) : nil)
        }
        let outside = NSPoint(x: shaped.frame.minX - margin / 2, y: shaped.frame.midY)
        let outsideTarget = target(hitWindow(at: outside, under: shaped), shaped: shaped, lower: lower)
        let notch = ProbeShape.clickSpots.first { $0.name == "notchTransparent" }!
        let notchPoint = ProbeWindows.screenPoint(notch, in: shaped)
        let raw = NSWindow.windowNumber(at: notchPoint, belowWindowWithWindowNumber: 0)
        let rawTopmost = target(raw, shaped: shaped, lower: lower) == .none ? windowOwner(raw) : target(raw, shaped: shaped, lower: lower).rawValue
        let aboveCount = windowsAbove(shaped).count

        lower.orderOut(nil)
        pump(0.4)
        let n = hitWindow(at: notchPoint, under: shaped)
        let alone = n == shaped.windowNumber ? "shaped" : "not ours: \(windowOwner(n))"

        let result = RoutingResult(ignores: ignores, getterValue: shaped.ignoresMouseEvents, windowsAboveProbe: aboveCount,
                                   rawTopmostAtNotch: rawTopmost, hits: hits,
                                   outsideShapedInsideLower: outsideTarget, notchWithLowerHidden: alone)
        shaped.close()
        lower.close()
        pump(0.2)
        return result
    }

    private static func dispatchResults(hitTestOverride: Bool, mask: Mask, topLeft: NSPoint) -> [DispatchResult] {
        let (shaped, view) = ProbeWindows.makeShaped(mask: mask, topLeft: topLeft, ignores: .unset, hitTestOverride: hitTestOverride)
        shaped.allowsKey = false
        shaped.orderFrontRegardless()
        pump(0.5)
        let spots = ProbeShape.clickSpots.filter { $0.name == "bodyOpaque" || $0.name == "notchTransparent" }
        let results = spots.map { spot -> DispatchResult in
            var received = false
            view.onMouseDown = { _, _, _ in received = true }
            let local = NSPoint(x: (CGFloat(spot.x) + 0.5) * ProbeShape.scale,
                                y: shaped.frame.height - (CGFloat(spot.y) + 0.5) * ProbeShape.scale)
            for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: shaped.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pressure
                ) {
                    shaped.sendEvent(event)
                }
            }
            let n = hitWindow(at: ProbeWindows.screenPoint(spot, in: shaped), under: shaped)
            return DispatchResult(hitTestOverride: hitTestOverride, spot: spot.name, maskOpaque: mask[spot.x, spot.y],
                                  viewGotMouseDown: received, windowServerTarget: target(n, shaped: shaped, lower: nil))
        }
        shaped.close()
        pump(0.2)
        return results
    }

    private static func shadowSamples(notched: Mask, topLeft: NSPoint, pngDir: String?) -> [ShadowSample] {
        let full = ProbeShape.mask(ProbeShape.fullRegion)
        var samples: [ShadowSample] = []
        let (window, view) = ProbeWindows.makeShaped(mask: full, topLeft: topLeft, ignores: .unset, hitTestOverride: false)
        window.allowsKey = false
        window.orderFrontRegardless()
        pump(0.8)
        samples.append(sample("1-full-rect", window, pngDir))
        view.setMask(notched)
        pump(0.8)
        samples.append(sample("2-notched-without-invalidateShadow", window, pngDir))
        window.invalidateShadow()
        pump(0.8)
        samples.append(sample("3-notched-after-invalidateShadow", window, pngDir))
        view.setMask(full)
        pump(0.8)
        samples.append(sample("4-back-to-full-without-invalidateShadow", window, pngDir))
        window.close()

        let (fresh, _) = ProbeWindows.makeShaped(mask: notched, topLeft: topLeft, ignores: .unset, hitTestOverride: false)
        fresh.allowsKey = false
        fresh.orderFrontRegardless()
        pump(0.8)
        samples.append(sample("5-new-window-created-notched", fresh, pngDir))
        fresh.close()
        pump(0.2)
        return samples
    }

    private static func sample(_ label: String, _ window: NSWindow, _ pngDir: String?) -> ShadowSample {
        let rect = cgGlobalRect(window.frame.insetBy(dx: -margin, dy: -margin))
        guard let image = captureOwnWindow(window.windowNumber, rect: rect), let pixels = RGBAPixels(image) else {
            return ShadowSample(label: label, captured: false, imageSize: [], alpha: [:], rowBelowBottom: [], notchColumn: [])
        }
        if let pngDir { writePNG(image, to: "\(pngDir)/shadow-\(label).png") }
        let pxPerPoint = CGFloat(image.width) / rect.width
        func alpha(_ sx: Int, _ sy: Int) -> Int {
            let x = (margin + (CGFloat(sx) + 0.5) * ProbeShape.scale) * pxPerPoint
            let y = (margin + (CGFloat(sy) + 0.5) * ProbeShape.scale) * pxPerPoint
            return pixels.alpha(Int(x), Int(y))
        }
        let named: [String: Int] = [
            "contentBody(40,60)": alpha(40, 60),
            "contentNotch(110,100)": alpha(110, 100),
            "contentCornerCut(0,0)": alpha(0, 0),
            "notchJustBelowTopEdge(108,43)": alpha(108, 43),
            "notchDeep(108,104)": alpha(108, 104),
            "belowLeftLeg(40,119)": alpha(40, 119),
            "belowNotch(108,119)": alpha(108, 119),
            "belowNotchCentre(137,119)": alpha(137, 119),
        ]
        return ShadowSample(
            label: label, captured: true, imageSize: [image.width, image.height], alpha: named,
            rowBelowBottom: stride(from: -15, through: 290, by: 5).map { alpha($0, 119) },
            notchColumn: stride(from: 30, through: 130, by: 4).map { alpha(108, $0) }
        )
    }
}
