// SPDX-License-Identifier: GPL-3.0-or-later
// Clicks reach the controls the way AppKit routes them: NSWindow.sendEvent hit-tests from the window's frame view,
// and the deepest view under the point gets the mouse-down. Labels and images inside a control must never be that
// view (an NSImageView inside a button swallowed every click once), and a card's background drags the window.
import AppKit
import Testing
@testable import ModernUI

@MainActor @Suite(.serialized) struct ModernHitTestTests {
    /// What AppKit's routing hits at the centre of `view` (or at `offset` from its top-left).
    func hit(_ window: NSWindow, _ view: NSView, offset: CGPoint? = nil) -> NSView? {
        let local = offset ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let inWindow = view.convert(local, to: nil)
        guard let frameView = window.contentView?.superview else { return nil }
        return frameView.hitTest(frameView.convert(inWindow, from: nil))
    }

    func name(_ view: NSView?) -> String { view.map { String(describing: type(of: $0)) } ?? "nil" }

    @Test func everyControlTakesItsOwnClicks() {
        let (player, _) = makePlayer(panels: [.equalizer, .stations])
        var state = playing()
        state.equalizer.preamp = 3
        player.state = state
        player.window.contentView?.layoutSubtreeIfNeeded()
        let root = player.window.contentView as! ModernRootView
        let np = root.nowPlaying, eq = root.equalizer
        let controls: [NSView] = [np.playButton, np.nextButton, np.previousButton, np.favouriteButton, np.shuffleButton,
                                  np.moreButton, np.genreButton, np.equalizerButton, np.stationsButton, np.appearanceButton,
                                  np.volume, np.progress, np.elapsedLabel, np.remainingLabel, np.artwork,
                                  eq.presetsButton, eq.resetButton, eq.toggle, eq.preamp] + eq.bands
        for control in controls {
            let got = hit(player.window, control)
            #expect(got === control, "\(name(control)) hit \(name(got))")
        }
        player.close()
    }

    @Test func textAndBackgroundsDragTheWindow() {
        let (player, _) = makePlayer(panels: [.equalizer])
        player.state = playing()
        player.window.contentView?.layoutSubtreeIfNeeded()
        let root = player.window.contentView as! ModernRootView
        for view in [root.nowPlaying.subtitleLabel, root.nowPlaying.formatLabel, root.equalizer.titleLabel] as [NSView] {
            let got = hit(player.window, view)
            #expect(got is DragSurface, "\(name(view)) hit \(name(got))")
        }
        let background = hit(player.window, root.nowPlaying, offset: CGPoint(x: 300, y: 8))
        #expect(background is DragSurface && background?.mouseDownCanMoveWindow == true, "background hit \(name(background))")
        #expect(hit(player.window, root.nowPlaying.titleView)?.mouseDownCanMoveWindow == true, "the title drags too")
        player.close()
    }

    @Test func clearMarginsBelongToNoView() {
        let (player, _) = makePlayer()
        guard let frameView = player.window.contentView?.superview else { return }
        let corner = frameView.hitTest(frameView.convert(CGPoint(x: 4, y: 4), from: nil))
        #expect(!(corner is DragSurface) && !(corner is NSControl), "margin hit \(name(corner))")
        player.close()
    }
}
