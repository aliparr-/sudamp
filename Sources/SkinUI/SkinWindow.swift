// SPDX-License-Identifier: GPL-3.0-or-later
// A borderless, clear, shadowed window that shows one SkinView (DESIGN §8.1, spike S1):
//
// - `canBecomeKey`/`canBecomeMain` are overridden (borderless windows answer false otherwise [measured]);
// - `ignoresMouseEvents` is NEVER assigned and there is no hitTest override: WindowServer then routes clicks on
//   alpha-0 (region.txt) pixels to the window below, and assigning even `false` would turn that off (S1);
// - the shadow follows the alpha shape; SkinView invalidates it after skin, shade or region changes;
// - AppKit's per-window constraining is disabled: WindowManager keeps docked groups on screen as a unit.

import AppKit
import SkinKit

public final class SkinWindow: NSWindow {
    public let role: SkinWindowRole
    public let skinView: SkinView
    /// The app's undo manager (Edit ▸ Undo reaches it through the responder chain from a skinned window).
    public var undoManagerProvider: (() -> UndoManager?)?

    public init(role: SkinWindowRole, skin: Skin, scale: Double, shaded: Bool = false) {
        self.role = role
        skinView = SkinView(role: role, skin: skin, scale: scale, shaded: shaded)
        super.init(contentRect: CGRect(origin: .zero, size: skinView.frame.size),
                   styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        tabbingMode = .disallowed
        collectionBehavior = [.fullScreenNone]
        title = role.title
        contentView = skinView
        makeFirstResponder(skinView)
    }

    override public var undoManager: UndoManager? { undoManagerProvider?() ?? super.undoManager }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    /// Docked windows move as a group; AppKit nudging one of them under the menu bar would split the group.
    override public func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override public func becomeKey() {
        super.becomeKey()
        skinView.setFocused(true)
    }

    override public func resignKey() {
        super.resignKey()
        skinView.setFocused(false)
    }
}
