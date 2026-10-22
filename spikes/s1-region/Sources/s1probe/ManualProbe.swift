// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1: `s1probe manual`, the interactive probe behind the owner's 5-minute checklist
// (docs/spikes/S1.md). Every click is logged in the window and on stdout, so the terminal output
// can be pasted into the report.
import AppKit
import RegionRaster

final class ManualProbe: NSObject, NSApplicationDelegate {
    private var lower: NSWindow!
    private var lowerView: LowerView!
    private var shaped: ShapedWindow?
    private var shapedView: ShapedView?
    private var ignores = IgnoresSetting.unset
    private var hitTestOverride = false
    private var showingNotch = true
    private var lineNumber = 0
    private let logView = NSTextView()
    private let ignoresPopup = NSPopUpButton()
    private let overrideBox = NSButton(checkboxWithTitle: "hitTest override (nil over alpha 0)", target: nil, action: nil)
    private static let contentSize = NSSize(width: 760, height: 640)

    static func run() -> Never {
        let app = NSApplication.shared
        let probe = ManualProbe()
        app.delegate = probe
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMenu()
        app.run()
        exit(0)
    }

    private static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit s1probe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(x: screen.visibleFrame.midX - Self.contentSize.width / 2,
                             y: screen.visibleFrame.midY - Self.contentSize.height / 2)
        (lower, lowerView) = ProbeWindows.makeLower(frame: NSRect(origin: origin, size: Self.contentSize),
                                                    title: "S1 lower window — an ordinary window")
        lowerView.onMouseDown = { [weak self] p in
            self?.log("LOWER window got the click at (\(Int(p.x)), \(Int(p.y))) pt")
        }
        buildControls()
        lower.makeKeyAndOrderFront(nil)
        NSApp.activate()
        recreateShaped(nil)
        log("s1probe manual: follow the checklist in docs/spikes/S1.md. Every click is logged here and on stdout.")
        // Layout self-check for the spike author: S1_SNAPSHOT_DIR=<dir> writes both windows as PNGs and quits.
        if let dir = ProcessInfo.processInfo.environment["S1_SNAPSHOT_DIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                for (name, window) in [("lower", self.lower as NSWindow?), ("shaped", self.shaped)] {
                    if let window, let image = captureOwnWindow(window.windowNumber, rect: cgGlobalRect(window.frame.insetBy(dx: -30, dy: -30))) {
                        writePNG(image, to: "\(dir)/manual-\(name).png")
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Controls

    private func buildControls() {
        ignoresPopup.addItems(withTitles: IgnoresSetting.allCases.map { "ignoresMouseEvents: \($0.rawValue)" })
        ignoresPopup.target = self
        ignoresPopup.action = #selector(settingsChanged(_:))
        overrideBox.target = self
        overrideBox.action = #selector(settingsChanged(_:))
        let row1 = NSStackView(views: [
            ignoresPopup, overrideBox,
            NSButton(title: "Recreate shaped window", target: self, action: #selector(recreateShaped(_:))),
        ])
        let row2 = NSStackView(views: [
            NSButton(title: "Swap shape (full ↔ notched)", target: self, action: #selector(swapShape(_:))),
            NSButton(title: "invalidateShadow()", target: self, action: #selector(invalidateShadow(_:))),
            NSButton(title: "Clear log", target: self, action: #selector(clearLog(_:))),
        ])
        let help = NSTextField(wrappingLabelWithString: """
            The teal shape is a borderless, non-opaque window (alpha 0 outside its region). Click the orange \
            stripes inside its notch, then its body and the diamond. Drag it by its body to move it over other \
            apps. Changing a setting recreates it.
            """)
        // A plain panel behind the controls keeps them readable; the stripes stay visible above it.
        let panel = NSView(frame: NSRect(x: 8, y: 6, width: Self.contentSize.width - 16, height: 358))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.layer?.cornerRadius = 6
        lowerView.addSubview(panel)
        for (view, y, height) in [(row1, 330.0, 28.0), (row2, 296.0, 28.0), (help as NSView, 240.0, 50.0)] {
            view.frame = NSRect(x: 16, y: y, width: Self.contentSize.width - 32, height: height)
            lowerView.addSubview(view)
        }
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 12, width: Self.contentSize.width - 32, height: 222))
        scroll.hasVerticalScroller = true
        scroll.documentView = logView
        logView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        logView.autoresizingMask = [.width]
        lowerView.addSubview(scroll)
    }

    @objc private func settingsChanged(_ sender: Any?) {
        ignores = IgnoresSetting.allCases[max(0, ignoresPopup.indexOfSelectedItem)]
        hitTestOverride = overrideBox.state == .on
        recreateShaped(sender)
    }

    @objc private func recreateShaped(_ sender: Any?) {
        shaped?.close()
        let content = lower.contentLayoutRect
        let frameTop = lower.frame.minY + content.maxY
        let topLeft = NSPoint(x: lower.frame.minX + 105, y: frameTop - 40)
        let mask = ProbeShape.mask(showingNotch ? ProbeShape.notchedRegion : ProbeShape.fullRegion)
        let (window, view) = ProbeWindows.makeShaped(mask: mask, topLeft: topLeft, ignores: ignores, hitTestOverride: hitTestOverride)
        view.dragsWindow = true
        view.onMouseDown = { [weak self] x, y, opaque in
            self?.log("SHAPED window got the click at skin pixel (\(x), \(y)), \(opaque ? "opaque" : "TRANSPARENT (alpha 0)") pixel")
        }
        window.orderFrontRegardless()
        shaped = window
        shapedView = view
        log("— shaped window created: ignoresMouseEvents=\(ignores.rawValue), hitTest override \(hitTestOverride ? "on" : "off"), shape \(showingNotch ? "notched" : "full")")
    }

    @objc private func swapShape(_ sender: Any?) {
        showingNotch.toggle()
        shapedView?.setMask(ProbeShape.mask(showingNotch ? ProbeShape.notchedRegion : ProbeShape.fullRegion))
        log("— shape swapped to \(showingNotch ? "notched" : "full") WITHOUT invalidateShadow(): look at the shadow below the notch")
    }

    @objc private func invalidateShadow(_ sender: Any?) {
        shaped?.invalidateShadow()
        log("— invalidateShadow() called: look at the shadow again")
    }

    @objc private func clearLog(_ sender: Any?) {
        logView.string = ""
    }

    private func log(_ message: String) {
        lineNumber += 1
        let line = String(format: "%03d ", lineNumber) + message
        print(line)
        fflush(stdout)
        logView.textStorage?.append(NSAttributedString(string: line + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor,
        ]))
        logView.scrollToEndOfDocument(nil)
    }
}
