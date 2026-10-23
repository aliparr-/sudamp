// SPDX-License-Identifier: GPL-3.0-or-later
// Core Animation must never be handed a lazily bridged Swift array as keyframe values: reading one during a commit
// crashed on macOS 26.6 (EXC_BAD_ACCESS in __SwiftDeferredNSArray from -[CAKeyframeAnimation CA_prepareRenderValue])
// as soon as the station list opened and its playing row's bars started to bounce.
import AppKit
import QuartzCore
import Testing
@testable import ModernUI

@MainActor @Suite(.serialized) struct ModernAnimationTests {
    func valuesClass(_ animation: CAKeyframeAnimation) -> String {
        guard let values = animation.value(forKey: "values") as AnyObject? else { return "nil" }
        return NSStringFromClass(type(of: values))
    }

    @Test func keyframeHelpersHandCoreAnimationPlainArrays() {
        let numbers = CAKeyframeAnimation(keyPath: "opacity")
        numbers.setKeyframes([0, 0.5, 1])
        #expect(!valuesClass(numbers).contains("Swift"), "\(valuesClass(numbers))")
        #expect((numbers.values as? [NSNumber])?.map(\.doubleValue) == [0, 0.5, 1])
        let objects = CAKeyframeAnimation(keyPath: "position")
        objects.setKeyframes(objects: [NSValue(point: .zero), NSValue(point: CGPoint(x: 1, y: 2))])
        #expect(!valuesClass(objects).contains("Swift"), "\(valuesClass(objects))")
        #expect(!NSStringFromClass(type(of: numberArray([1, 2]))).contains("Swift"))
    }

    /// Every keyframe animation running in the window while it plays, with the station list open (the playing row's
    /// bars), a title long enough to glide (scroll and edge fade) and the artwork's drifting light.
    @Test func noRunningAnimationHoldsALazySwiftArray() {
        let (player, _) = makePlayer(panels: [.stations, .equalizer])
        var state = playing()
        state.title = "A title far too long to fit on the player card, so it has to glide across it slowly"
        player.state = state
        let root = player.window.contentView!
        root.layoutSubtreeIfNeeded()
        for view in allViews(root) { view.layoutSubtreeIfNeeded() }
        var keyframes: [(String, CAKeyframeAnimation)] = []
        func walk(_ layer: CALayer) {
            for key in layer.animationKeys() ?? [] {
                if let animation = layer.animation(forKey: key) as? CAKeyframeAnimation { keyframes.append((key, animation)) }
            }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
            if let mask = layer.mask { walk(mask) }
        }
        // Through every view's own layer: glass may host its content's layers apart from the root's tree.
        for view in allViews(root) { if let layer = view.layer { walk(layer) } }
        let keys = Set(keyframes.map(\.0))
        if Motion.reduced {
            // Reduce Motion: nothing loops, so there is nothing to check but that.
            #expect(!keys.contains("drift") && !keys.contains("scroll"), "running: \(keys.sorted())")
        } else {
            #expect(keys.isSuperset(of: ["bounce", "scroll", "edges", "drift"]), "running: \(keys.sorted())")
        }
        for (key, animation) in keyframes {
            #expect(!valuesClass(animation).contains("Swift"), "\(key): \(valuesClass(animation))")
        }
        player.close()
    }

    func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
