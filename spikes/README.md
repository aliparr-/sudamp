# Spikes

Throwaway experiments that the design in `docs/DESIGN.md` relies on. This is not product code: it's kept so the measurements can be re-run and the M0 port has a starting point.

## `engine-pull-ao/`: libmpv → AVAudioEngine pull audio output (2026-10-22)

The question was how to get libmpv's decoded audio into our own AVAudioEngine graph (for EQ, the visualiser and device handling) without mpv's CoreAudio output.

- `Sources/SudampAO/sudamp_ao.c` (78 lines) defines `audio_out_pcm` as a **pull** AO. MPVKit 1.0.0's static libmpv exports only that symbol from its `ao_pcm` object, so ours wins at link time. An `AVAudioSourceNode` render block calls `sudamp_ao_read()`, which calls mpv's `ao_read_data()`, the same call `ao_coreaudio` makes.
- `Sources/spikepull/` is the harness: graph, transport timings, EQ measurement and an internet-radio test. `Sources/spike/` holds the rejected `ao=pcm` → FIFO experiment plus the lavfi-EQ checks.
- `iso6/` reproduces the Swift 6 crash when an `AVAudioSourceNode` block is created on the `@MainActor`.
- `runs/` and `analysis/` hold raw logs and the scripts used to analyse them.

Headline results (macOS 27.0.1, M5 Pro, release build):

| Pipeline | Pause | Seek | Load next file | CPU |
|---|---|---|---|---|
| Pull AO → AVAudioEngine | ≤ 9.6 ms | 9.6–10.8 ms, 0 stale frames | ≈ 24 ms | 1.1% |
| `ao=pcm` → FIFO (rejected) | 1.93 s | 1.7–2.7 s of stale audio | — | — |

The FIFO approach also blocks the mpv core for about 1.3 s per write and deadlocks when the reader stalls. Full write-up: `docs/research/eval-enginespike.md`.

**To rebuild:** `Package.swift` points `-I` at an mpv v0.41.0 source checkout in `/tmp`. Clone `https://github.com/mpv-player/mpv` at tag `v0.41.0` and update the `mpvSrc` constant. `sudamp_ao.c` is built against mpv's internal LGPL-2.1+ headers, so treat it as LGPL-2.1+.

## `skins-tools/`: Webamp sprite-table extraction

- `extract_sprites.py` turns Webamp's `packages/webamp/js/skinSprites.ts` (commit `7734cd3`) into `webamp_sprites.json` (212 sprites). The table is derived from Webamp, MIT © 2015 Jordan Eldredge.
- `compare_sprites.py` and `webamp_ref.py` cross-check the sprite tables of other Swift ports against Webamp's.
- `parser-harness.swift` exercises the viscolor, pledit and region parsers against Webamp's fixtures.

M4 turns `extract_sprites.py` into `scripts/gen-sprites.py`.

## `s1-region/`: region.txt rasteriser and shaped-window probe (2026-10-22)

Spike S1 (`docs/spikes/S1.md`). `RegionRaster` is a pure, non-anti-aliased polygon rasteriser (even-odd or non-zero, poly-polygon or union, right and bottom edges exclusive) with 20 pixel-exact Swift Testing tests. `s1probe measure` asks the WindowServer (`windowNumberAtPoint:belowWindowWithWindowNumber:`) which window a click on a shaped window would hit, and captures the window's shadow; neither needs permissions. `s1probe manual` is the owner's 5-minute checklist. Result: alpha-0 pixels pass clicks through by default, and assigning `ignoresMouseEvents = false` turns that off.

