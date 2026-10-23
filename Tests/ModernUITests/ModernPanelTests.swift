// SPDX-License-Identifier: GPL-3.0-or-later
// DESIGN §8.4: panels open and close like drawers (never over the card above), the card shadows fade out inside the
// window's clear margin (no edge of them shows), and the visualiser's own check of whether the window shows.
import AppKit
import QuartzCore
import Testing
@testable import ModernUI

@MainActor @Suite(.serialized) struct ModernPanelTests {
    func root(_ player: ModernPlayer) -> ModernRootView { player.window.contentView as! ModernRootView }

    /// Steps a running panel animation frame by frame, checking each frame.
    func step(_ root: ModernRootView, check: (Double) -> Void) {
        guard let start = root.cardAnimationStart else { return }
        for frame in 0...40 {
            let t = Double(frame) / 40
            root.stepCards(at: start + t * CardSpring.duration)
            root.layoutSubtreeIfNeeded()
            check(t)
        }
    }

    @Test func theClosingEqualizerFoldsUpUnderThePlayerNotIntoIt() {
        guard !Motion.reduced else { return }
        let (player, _) = makePlayer(panels: [.equalizer, .stations])
        let view = root(player)
        view.animatesOffscreen = true
        let np = view.nowPlaying.frame
        let top = view.equalizer.frame.minY
        let windowHeight = player.window.frame.height
        player.setPanel(.equalizer, open: false)
        #expect(view.isAnimatingCards)
        var heights: [CGFloat] = []
        step(view) { t in
            guard view.isAnimatingCards else { return }
            let eq = view.equalizer.frame, st = view.stations.frame
            heights.append(eq.height)
            #expect(eq.minY == top, "the top edge stays a gap under the player at \(t)")
            #expect(eq.minY >= np.maxY + Metrics.gap && st.minY >= eq.maxY, "no overlap at \(t)")
            #expect(view.equalizer.content.alphaValue <= 1)
            #expect(player.window.frame.height == windowHeight, "the window shrinks after, not during")
        }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 >= $1 }, "it only ever closes")
        #expect(!view.isAnimatingCards && view.equalizer.isHidden)
        #expect(view.stations.frame == ModernGeometry.frames(open: [.stations])[.stations])
        #expect(player.window.frame.size == ModernGeometry.windowSize(open: [.stations]))
        player.close()
    }

    @Test func anOpeningPanelGrowsDownFromItsTopEdge() {
        guard !Motion.reduced else { return }
        let (player, _) = makePlayer()
        let view = root(player)
        view.animatesOffscreen = true
        player.setPanel(.stations, open: true)
        #expect(player.window.frame.size == ModernGeometry.windowSize(open: [.stations]), "the window grows first")
        let rest = ModernGeometry.frames(open: [.stations])[.stations]!
        step(view) { t in
            let st = view.stations.frame
            #expect(st.minY == rest.minY && st.height <= rest.height, "inside its resting frame at \(t)")
        }
        #expect(view.stations.frame == rest && view.stations.content.alphaValue == 1 && view.stations.pageOffset == 0)
        player.close()
    }

    /// The shadows fade to nothing inside the clear margin: cut off at the window's edge, a 10% shadow showed as a
    /// straight line under the cards.
    @Test func shadowsFadeOutInsideTheWindow() throws {
        for dark in [false, true] {
            let size = ModernGeometry.windowSize(open: [.stations])
            let shadows = CardShadowView(frame: CGRect(origin: .zero, size: size))
            shadows.apply(ModernPalette(tint: .teal, appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!))
            let frames = ModernGeometry.frames(open: [.stations])
            shadows.update(frames.map { CardShadowView.Card(id: ObjectIdentifier(NSNumber(value: $0.key.hashValue)),
                                                             frame: $0.value, opacity: 1) })
            let layer = try #require(shadows.layer)
            let width = Int(size.width), height = Int(size.height)
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            layer.render(in: context)
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4 + 3] }
            var edge: UInt8 = 0
            for x in 0..<width { edge = max(edge, alpha(x, 0), alpha(x, height - 1)) }
            for y in 0..<height { edge = max(edge, alpha(0, y), alpha(width - 1, y)) }
            #expect(edge <= 1, "\(dark ? "dark" : "light"): the shadow reaches the window's edge at alpha \(edge)/255")
            // And there is a shadow: just below the bottom card it is plainly there (the bitmap's rows may run either
            // way: the view is flipped, the context isn't).
            let bottom = frames[.stations]!
            let below = Int(bottom.maxY) + 3
            let shadow = max(alpha(Int(bottom.midX), below), alpha(Int(bottom.midX), height - 1 - below))
            #expect(shadow > 8, "\(dark ? "dark" : "light"): \(shadow)/255 just below the card")
        }
    }

    @Test func coveredMeansEveryPartIsUnderAWindowAbove() {
        let card = CGRect(x: 100, y: 100, width: 380, height: 262)
        #expect(WindowVisibility.uncovered([card], above: []))
        #expect(!WindowVisibility.uncovered([card], above: [CGRect(x: 0, y: 0, width: 2000, height: 1200)]), "the lock screen's shield")
        #expect(WindowVisibility.uncovered([card], above: [CGRect(x: 0, y: 0, width: 300, height: 1200)]), "half covered still shows")
        #expect(!WindowVisibility.uncovered([card], above: [CGRect(x: 0, y: 0, width: 300, height: 1200),
                                                            CGRect(x: 290, y: 0, width: 400, height: 1200)]), "covered by two")
        #expect(!WindowVisibility.uncovered([CGRect(x: 10, y: 10, width: 0, height: 50)], above: []), "nothing to see")
    }
}
