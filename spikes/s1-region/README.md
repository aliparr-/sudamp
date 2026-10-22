# Spike S1: region.txt rasteriser and shaped-window probe

Standalone SwiftPM package; it is not part of the app build. The report is `docs/spikes/S1.md`.

- `Sources/RegionRaster/` is pure Swift with no Foundation: a non-anti-aliased polygon rasteriser (even-odd or non-zero; one poly-polygon or a union; right and bottom edges exclusive) plus a minimal region.txt section reader. M4 moves the rasteriser into SkinKit; the parser there will be macamp's.
- `Tests/RegionRasterTests/` holds pixel-exact Swift Testing cases with hand-computed masks, plus a brute-force cross-check on seeded random polygons.
- `Sources/s1probe/` is the AppKit probe:
  - `s1probe check`: Accessibility, post-event and screen-capture state, read with the non-prompting preflight calls.
  - `s1probe measure [--png <dir>]`: headless and needs no permission. It asks WindowServer which window a mouseDown would hit (`+[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:]`) for each `ignoresMouseEvents` state, and captures its own window to measure the shadow. Output is JSON.
  - `s1probe auto`: real `CGEvent` clicks. It runs only if the terminal already has Accessibility permission (it never prompts) and is **untested**.
  - `s1probe manual` (the default): the interactive probe for the owner's 5-minute checklist.
- `runs/` holds the 2026-10-22 `measure` output and two of its shadow captures.

```sh
cd spikes/s1-region
swift test -Xswiftc -plugin-path -Xswiftc "$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins/testing"
swift run s1probe measure | jq '.routing'
swift run s1probe manual
```
