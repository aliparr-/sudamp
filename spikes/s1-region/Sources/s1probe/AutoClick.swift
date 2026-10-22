// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: `s1probe auto`, real clicks through the HID event tap. Only runs when the terminal
// already has Accessibility permission; it never asks for it. NOT RUN in the 2026-10-22 spike
// (no permission on the dev machine), so treat it as untested.
import AppKit
import RegionRaster

struct AutoClickResult: Codable {
    let ignores: IgnoresSetting
    let hitTestOverride: Bool
    let spot: String
    let maskOpaque: Bool
    let receivedBy: ClickTarget
}

struct AutoClickReport: Codable {
    let permissions: Permissions
    let skipped: String?
    let results: [AutoClickResult]
}

enum AutoClick {
    static func run() -> Int32 {
        let permissions = Permissions.current()
        guard permissions.accessibility, permissions.postEvents else {
            printJSON(AutoClickReport(
                permissions: permissions,
                skipped: "no Accessibility/post-event permission: run the manual checklist in docs/spikes/S1.md",
                results: []
            ))
            return 2
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        // Put the pointer back where the owner left it, whatever happens below.
        let savedCursor = CGEvent(source: nil)?.location
        defer { if let savedCursor { CGWarpMouseCursorPosition(savedCursor) } }

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let topLeft = NSPoint(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.maxY - 120)
        let mask = ProbeShape.mask(ProbeShape.notchedRegion)
        let size = NSSize(width: CGFloat(mask.width) * ProbeShape.scale, height: CGFloat(mask.height) * ProbeShape.scale)
        let lowerFrame = NSRect(x: topLeft.x - 40, y: topLeft.y - size.height - 40, width: size.width + 80, height: size.height + 80)

        var results: [AutoClickResult] = []
        for ignores in IgnoresSetting.allCases {
            for hitTestOverride in [false, true] {
                let (lower, lowerView) = ProbeWindows.makeLower(frame: lowerFrame, title: "S1 lower (auto)")
                lower.level = .floating
                lower.orderFrontRegardless()
                let (shaped, shapedView) = ProbeWindows.makeShaped(
                    mask: mask, topLeft: topLeft, ignores: ignores, hitTestOverride: hitTestOverride)
                shaped.orderFrontRegardless()
                var last = ClickTarget.none
                lowerView.onMouseDown = { _ in last = .lower }
                shapedView.onMouseDown = { _, _, _ in last = .shaped }
                pump(0.6)
                for spot in ProbeShape.clickSpots {
                    last = .none
                    let p = cgGlobalPoint(ProbeWindows.screenPoint(spot, in: shaped))
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                            .post(tap: .cghidEventTap)
                    }
                    pump(0.3)
                    results.append(AutoClickResult(ignores: ignores, hitTestOverride: hitTestOverride, spot: spot.name,
                                                   maskOpaque: mask[spot.x, spot.y], receivedBy: last))
                }
                shaped.close()
                lower.close()
                pump(0.2)
            }
        }
        printJSON(AutoClickReport(permissions: permissions, skipped: nil, results: results))
        return 0
    }
}
