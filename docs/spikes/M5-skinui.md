# M5 groundwork: SkinUI (skinned windows) and the skin preview

*2026-10-22 · agent: skinui · scratch path `.build-skinui` · status: SkinUI and `sudamp --skin-preview` implemented and
verified headlessly and on the live WindowServer session; nothing is wired to playback yet (that is M5's Shell work).*

Everything below was run on the dev machine (macOS 27.0.1, M5 Pro, Command Line Tools only, Swift 6.4). The only
display is **1x** (`backingScaleFactor` 1.0, 1920×1080), and the **screen was locked** for the whole session
(`CGSSessionScreenIsLocked = 1`); see "Conditions" for what that means for each check.

## What exists

| Task item | Where | State |
|---|---|---|
| `SkinWindow`: borderless, clear, `hasShadow`, key/main overrides, custom drag, never assigns `ignoresMouseEvents`, no `hitTest` override | `Sources/SkinUI/SkinWindow.swift` | done, tested |
| Layer tree: base = SkinKit 1x frame (`.nearest`, `.resize`), visualiser and marquee sublayers, Core Text title overlay, region alpha from SkinKit | `Sources/SkinUI/SkinView.swift` | done; on-screen pixel-exact at 1/2/3x (capture check) |
| 30 Hz redraw via `NSView.displayLink` without recomposing the base | `SkinView` | done; on demand (30 Hz only while something animates), paused when occluded |
| Input: hit-test → pressed sprites, release-inside, menus on press, sliders, marquee click vs scrub, double-click shade, right/control-click | `Sources/SkinUI/SkinInteraction.swift` (pure) + `SkinView` | done, tested |
| `SkinControlEvent` | `Sources/SkinUI/SkinControlEvent.swift` | done (all requested cases + a few extras, below) |
| `SkinPlayerState` → SkinKit `WindowState`; visualiser value type | `Sources/SkinUI/SkinPlayerState.swift` | done; mapping reproduces the M4 fixtures |
| `WindowManager`: docking/snapping (15 px), cluster drag with child windows only during the drag, persistence, screen clamp, shade, scale, always on top, show/hide, skin switching, region kill switch | `Sources/SkinUI/WindowManager.swift`, `DockingGeometry.swift` (pure), `WindowLayout.swift` | done, tested |
| NSAccessibility element for every hotspot (role, label, value, press, increment/decrement) | `Sources/SkinUI/SkinAccessibility.swift` | done, tested |
| `sudamp --skin-preview` | `Sources/Shell/SkinPreview.swift` | done; plus debug `--exercise` and `--verify-capture` checks |
| Tests | `Tests/SkinUITests/*` | **99 tests in 15 suites**, all pass |

No SkinKit file was changed. SkinKit's 103 tests and goldens still pass (`--filter SkinKitTests`, run after all
SkinUI work).

## Public API (what Shell M5 codes against)

```swift
// Windows
let manager = WindowManager(skin: SudampDark.skin, configuration: config)   // config.layoutURL = <profile>/layout.json
manager.show()
manager.playerState = state                     // SkinPlayerState, push on every change (elapsed ≥ 1 Hz is enough)
manager.visualizerProvider = { analyser.snapshot() }   // @MainActor () -> VisualizerSnapshot?, pulled ≤ 30 Hz
manager.onEvent = { event, window in … }        // (SkinControlEvent, SkinWindowRole)
manager.toggleScale() / setScale(1|2|3) / setAlwaysOnTop(_) / setOpen(_:_) / setShaded(_:_) / setSkin(_)
manager.setRegionEnabled(_)                     // S1 kill switch
manager.saveLayout() / close()                  // quit path: saveLayout() is already called after every change
```

- `SkinPlayerState`: title, playState (stopped/playing/paused), working (buffering), elapsed, duration (nil = live),
  timeDisplay (elapsed/remaining), kbps, khz, stereo (true/false/nil), volume 0…1, balance −1…1, equalizer
  {enabled, auto, preamp dB, 10 band dB}, shuffle, repeat, playlist rows {tag YT/SC/MC/FM, title, duration or nil =
  live}, currentRow, visualizerMode, alwaysSkinFont, liveLabel.
- `VisualizerSnapshot`: 19 bar heights 0…1, 76 scope samples −1…1, optional peaks 0…1 (otherwise SkinUI's
  `PeakTracker` draws falling peaks). The audio agent's analyser output only needs normalising into this.
- `SkinControlEvent`: play, pause, stop, next, previous, eject, seek(fraction:), volume(_), balance(_),
  eqBand(index:decibels:), preamp(decibels:), eqToggle (EQ ON), eqAuto, presetsMenu(screenPoint:), shuffle,
  repeat, plToggle, eqWindowToggle, marqueeClick(screenPoint:), optionsMenu(screenPoint:),
  contextMenu(screenPoint:), minimize, shade(role), close(role), playlistRowActivated(index:),
  playlistScroll(firstRow:). **Extras:** eqSetAll(decibels:) (the +12/0/−12 labels), timeModeToggle,
  visualizerModeToggle, clutter(O/A/I/D/V, screenPoint:), about, playlistMenu(add/remove/select/misc/list,
  screenPoint:), playlistRowSelected(index:). Screen points are AppKit global coordinates, ready for
  `NSMenu.popUp(positioning:at:in: nil)`. `event.opensMenu` says whether the event anchors a menu.
- With `handlesWindowEvents` (default) WindowManager applies shade, minimise (Winamp-style: Main to the Dock, the
  others hide until it returns), EQ/PL toggles, EQ/PL close, clutter A (always on top) and clutter D (scale) itself,
  then forwards every event. `close(.main)` is only forwarded: closing Main is the app's quit path (DESIGN §3).
- Keys Z/X/C/V/B arrive as previous/play/pause/stop/next events from whichever skinned window is key.
- Pure, reusable pieces: `SkinStateMapper`, `SkinScale`, `SliderTrack`/`SliderValues`, `SkinInteraction`,
  `MarqueeClock`, `PauseBlink`, `VisualizerAdapter`, `PeakTracker`, `DockingGeometry`, `WindowLayout`.

## Design decisions (deliberate, tested)

- **Layer-hosting view, geometry flipped.** SkinView owns its root layer (`isGeometryFlipped = true`), so sublayer
  frames are skin rectangles × scale. Pixel layers use `.resize` + `.nearest` at whole-point frames; with whole-point
  window origins every skin pixel is exactly scale × backing device pixels (verified on screen, below).
- **The base recomposes rarely.** The base is rendered with `drawDynamicLayers = false`, the title blanked and the
  marquee step zeroed, and elapsed floored to whole seconds, so only real pixel changes (a second ticking, a pressed
  button, a moved slider, new state) recompose it; scrolling only redraws the 154×6 marquee layer (tested by
  identity of the base layer's `contents`).
- **On-demand display link.** 30 Hz while the visualiser animates (playing) or the title scrolls, 10 Hz for the
  paused blink only, stopped otherwise; the EQ window never ticks. A fully occluded window stops ticking
  (`pausesWhenOccluded`, default on). While paused, the visualiser keeps its last frame instead of pulling the
  provider.
- **Docking space.** Whole points in "top-left space" (y = −maxY), which is translation-invariant, so SkinKit's
  SnapGeometry applies unchanged. The snap distance is 15 points at every scale (Webamp's 15 CSS px in double mode);
  docking relations are scale-independent because a scale change rescales every offset around Main's top-left.
  DESIGN §8.1 says "docking maths stays in skin pixels": the relations do, positions are points (screen edges and
  menu bars are not on the skin-pixel grid, e.g. a 37-point menu bar).
- **Docked = touching exactly** (Webamp `areTouching`), and closed windows keep linking the chain (MacAmp), so a
  hidden EQ between Main and the Playlist still holds them together. Snapping targets visible windows only.
- **Screen edges snap, they do not clamp** during a drag (Webamp's `snapWithin` assumes one viewport and would trap
  windows on one display); the group is pushed out of a menu-bar strip (MacAmp's rule). After display changes and
  wake (1 s / 3 s settle), stranded groups are clamped back on screen as a unit (port of MacAmp's ScreenClamp).
- **Shade and scale state live in WindowManager** (they change window frames and are persisted with the layout),
  not in `SkinPlayerState`. Playlist shade is not in v1 (`shade(.playlist)` is forwarded, nothing changes).
- **⌘D / clutter D** toggles 1x ↔ 2x (from 3x it goes to 1x); `cycleScale()` and `setScale(3)` reach 3x. Clutter D
  lights when the scale is ≥ 2. Default scale: 2 on Retina, else 1 (this machine: 1).
- **Sliders** grab the thumb where pressed, or jump the thumb's middle to the pointer (Webamp's range inputs).
  Volume, balance, EQ bands, preamp and the playlist scrollbar send values while dragging; the position slider
  previews and seeks on release, and is inert without a duration (live) or when stopped. Balance within ±25 % snaps
  to the centre (Webamp `setBalance`); EQ values use EQSliderGeometry's ±0.6 dB flat snap.
- **Marquee.** A press that moves < 3 points is a click (`marqueeClick` on release); further movement scrubs the
  title (text follows the pointer, Webamp's `-diff`), scrolling resumes 1 s after release, and a new title restarts
  from the beginning. Paused time blinks like Webamp (`blink 2s step-start 1s`).
- **Menus open on press** (options, EQ presets, playlist menu buttons): the view draws the pressed sprite, flushes
  the transaction, delivers the event, then ends the gesture itself, since a pop-up menu swallows the mouse-up.
- **Slider overrides** keep the thumb under the pointer until the app's next state arrives; state updates clear
  them except for the slider still being dragged.

## Gates

| Gate | Command / method | Result |
|---|---|---|
| SkinUI tests | `swift test --scratch-path .build-skinui -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter SkinUITests` | **GO**: 99 tests in 15 suites pass (~2 s) |
| SkinKit unchanged | same with `--filter SkinKitTests` | **GO**: 103 tests in 23 suites pass |
| Whole suite, parallel (as `make test`) | `swift test --parallel --scratch-path .build-skinui …` | SkinUI's 99 pass alongside the rest; the only failures in that run were 3 issues in `PlaybackControllerTests` (playback agent's in-progress target, not SkinUI) |
| Zero new warnings | touched every SkinUI/Shell-preview/SkinUITests file, rebuilt `sudamp` and the tests, `scripts/check-warnings.sh` | **GO**: only the allow-listed CLT `ld` search-path warnings |
| Concurrency escapes | `scripts/count-escapes.sh` | **GO for SkinUI/Shell preview: 0 escapes.** The script as a whole currently fails on `Sources/Audio/{AudioEngine,RenderBridge}.swift` (audio agent's files, not mine) |
| `sudamp --skin-preview` launches | `perl -e 'alarm 3; exec @ARGV' .build-skinui/debug/sudamp --skin-preview` (killed by SIGALRM after 3 s, exit 142) | **GO**: stderr only has the expected log: skin, "windows created (scale 1, display backing 1.0x)" and the three frames `main (822,686 275x116)`, `equalizer (822,570 275x116)`, `playlist (822,338 275x232)`, all `visible=true`, docked; no errors |
| Interaction on the live session | `sudamp --skin-preview --exit-after 6 --exercise --verify-capture --ignore-occlusion` (debug), scales 1, 2, 3 and AndAmp Dark (2x) / Light (3x) | **GO**: 12/12 checks each: Main drag moves the docked cluster; EQ and Playlist attached as child windows during the drag and detached after; WindowServer's own window bounds (`CGWindowListCopyWindowInfo`) equal AppKit's frames; EQ drags alone and snaps back under Main from 6/2 points away; double-click shades and unshades Main with the stack following; Main's EQ button hides/shows the EQ window; a volume drag sends 7 `volume` events and the thumb is redrawn at the new value; clutter D toggles the scale with the stack docked |
| On-screen pixel exactness | same runs: own-window capture (`CGWindowListCreateImage` looked up at run time as in S1; no Screen Recording permission), compared skin pixel by skin pixel with base + marquee + visualiser layers | **GO**: every on-screen skin pixel is a uniform block of scale × scale device pixels with **max channel delta 0** against the composer output, at 1x, 2x and 3x, for sudamp Dark and both AndAmp skins; AndAmp's region pixels (100 per Main/EQ window) are transparent on screen (0 leaks) |
| Screenshots | — | **Not possible**: Screen Recording permission is not granted (and not to be prompted); the own-window capture above is the substitute |
| Real clicks / drags with the hardware mouse | — | **NOT-RUN**: needs Accessibility permission (synthetic `CGEvent`s) or a human; the in-process `NSEvent`s above go through the same `NSWindow.sendEvent` → view → WindowManager path |

### Conditions and what they mean

- **Locked screen.** All windows report `occlusionState` without `.visible` (the lock shield covers them), so by
  default the display link stays paused — exactly the "paused when occluded" behaviour. To exercise the animation
  path anyway the runs above used `--ignore-occlusion` (sets `pausesWhenOccluded = false`): Main ticked ~180 times
  in 6 s (30 Hz), the EQ and Playlist 0 times (nothing to animate). Own-window capture still works on a locked screen
  (as in S1).
- **1x display only.** On this display scale 2 means 2 device pixels per skin pixel; a 2x Retina backing store
  (4 or 6 device pixels per skin pixel) was **not** measured. The maths is the same (integer factors), and the
  Core Text overlay's `contentsScale` follows `backingScaleFactor`, but this is [unverified] until run on a Retina
  display.
- **3x stack on 1080p.** At 3x, Main + EQ + Playlist are 1,392 points tall; the clamp keeps the stack's top on
  screen and the Playlist runs off the bottom (MacAmp's rule for oversized groups). The capture check only compares
  on-screen pixels.

## Measurements

| What | Result |
|---|---|
| Release preview CPU, scale 2, animating (30 Hz visualiser + marquee + the preview's 4 Hz fake clock), `--ignore-occlusion`, `top -l 22 -s 1` | mean **1.06 %** of one core over 20 s (max 1.9 %) |
| Same, default (occluded by the lock screen → display link paused) | mean **0.55 %** (max 0.7 %); what remains is the preview's 4 Hz state pushes |
| Display-link rate while animating | ~30 Hz on Main (≈180 ticks in 6 s), 0 on EQ and Playlist |
| Composer cost per recompose | SkinKit's numbers apply (Main 0.15 ms, Playlist 0.29 ms release); the base recomposes ≤ 1×/s while playing |

These are preview numbers, not PLAN M5's gate (that one is the release app with real audio, `top -l 60`).

## Not done / open

- **Not wired to playback**: Shell M5 composes WindowManager with PlaybackController, the genre NSMenu (all anchors),
  presets menu, Open Stream URL, skins loading UI, `--snapshot`, automation hooks.
- **Playlist rows' Core Text overlay** for titles the pixel font lacks (DESIGN §8.3) is not implemented: rows are
  drawn by SkinKit's pixel font, transliterated (SkinKit flags it in `metadata.playlistFallback`). The marquee's
  overlay is implemented.
- **Retina 2x backing** and **real hardware clicks** (incl. S1's click-through checklist through SkinWindow) are
  unverified here (no Retina display; no Accessibility permission). M5's manual checklist covers both.
- **Seek flicker**: after a seek the thumb shows the target until the next state update, then whatever the app
  reports; if the app reports the old position once before mpv has seeked, the thumb jumps back for one update.
- **Display rearrangement** is handled by clamping stranded groups after a 1 s settle (3 s after wake). MacAmp's
  extra translate-with-the-display and rigid re-form steps were not ported.
- Mouse-wheel volume on Main is ±2 % per step; the hold-to-repeat of the playlist scroll buttons is not implemented.
- Playlist shade/resize, EQ presets content, gen.bmp windows, cursors: out of v1 scope (DESIGN §2).

## How to try it

```
swift build --product sudamp
.build/debug/sudamp --skin-preview                       # sudamp Dark, 2x on Retina / 1x otherwise
.build/debug/sudamp --skin-preview --skin Fixtures/skins/AndAmp-Dark.wsz --scale 2
.build/debug/sudamp --skin-preview --scale 3 --exit-after 6 --exercise --verify-capture   # debug self-checks, exit 0 = pass
```

In the preview: drag by the title bars (Main carries what is docked to it), double-click a title bar for shade,
right-click for a menu with Double Size / scales / Always on Top / Region Shaping / Regroup, click the marquee or the
options button for the stand-in genre menu, View menu (⌘D double size), ⌘Q quits. Every event is printed to stderr.
