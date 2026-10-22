// SPDX-License-Identifier: GPL-3.0-or-later
// SkinUI module (main actor by default) — skinned windows, layers, controls, docking. See docs/DESIGN.md §8 and
// docs/spikes/M5-skinui.md.
//
// Pure, nonisolated parts (testable without windows): SkinControlEvent, SkinPlayerState → WindowState mapping
// (SkinStateMapper), SkinScale, slider tracks, the pointer state machine (SkinInteraction), the marquee/blink
// clock, the visualiser adapter, docking geometry (DockingGeometry) and the layout file (WindowLayout).
// AppKit parts: SkinView (layer tree, input, 30 Hz display link, accessibility), SkinWindow and WindowManager
// (docking drags, shade, scale, always on top, persistence, screen guard, skin switching).

public enum SkinUIModule {
    public static let name = "SkinUI"
}
