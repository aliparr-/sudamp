# M4 progress: SkinKit and sudamp Dark

*2026-10-22 · agent: skinkit · scratch path `.build-skinkit` · status: priorities 1–7 implemented and tested
headlessly; `make skin-check`, `make golden` and PROVENANCE entries need orchestrator changes (listed at the end).*

Everything below was run on the dev machine (macOS 27.0.1, M5 Pro, CLT only, Swift 6.4).

## What exists

| PLAN M4 item | Where | State |
|---|---|---|
| ZIP reader with caps before allocation | `Sources/SkinKit/Zip/ZipArchive.swift` (Bitamp port) | done, tested |
| Whitelisted basename matching (images last, pledit.txt first) | `Archive/SkinArchive.swift` | done, tested |
| ImageIO decoding → opaque sRGB RGBA8, clipping, per-sheet fallback | `Image/SheetDecoder.swift`, `Image/Bitmap.swift`, `Skin.swift`, `SkinLoader.swift` | done, tested |
| Sprite table generated from Webamp | `scripts/gen-sprites.py` → `Generated/SpriteTable.swift` | done; 212/212 equal, 0 overrides |
| Layout draw rects + hit-testing (Main, shade, EQ, EQ shade, Playlist 275x232) | `Render/Layout.swift` | done, tested |
| ini / viscolor / pledit / region parsers | `Text/SkinTextParsers.swift` | done; Webamp's 7 region, 4 viscolor, 4 pledit fixtures pass |
| Region rasteriser (non-AA, even-odd, right/bottom exclusive) | `Region/RegionRasterizer.swift` | done, tested |
| Text: FONT_LOOKUP, deburr, marquee model, system-font fallback flag, transliteration | `Text/SkinFontText.swift` | done, Webamp marquee tests pass |
| Visualiser renderer | `Render/Visualizer.swift` | done (spectrum, scope, shade strip) |
| EQ slider geometry (51 px) + eqmain curve | `Render/EQGeometry.swift` | done, Webamp Band tests pass |
| Window composer | `Render/WindowComposer.swift`, `Render/WindowState.swift` | done: main, shade, eq, eq-shade, playlist |
| sudamp Dark generator + skingen | `Generator/*`, `Sources/skingen/main.swift` | done; byte-stable |
| `sudamp-dev render` / `skin-load` / `skin-fuzz` | `Sources/sudamp-dev/Commands/{Render,SkinLoad,SkinFuzz}.swift` | done |
| Goldens: sudamp Dark (13 states), AndAmp Dark (4) | `Fixtures/states/*.json`, `Fixtures/states/goldens.json` | done |
| Webamp snapUtils cases on pure docking geometry | `Docking/SnapGeometry.swift` | done (extra; SkinUI may build on it) |

## Gates run

| Gate (PLAN M4) | Command | Result |
|---|---|---|
| Unit tests | `swift test --scratch-path .build-skinkit -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter SkinKitTests` | **GO**: 103 tests in 23 suites pass (~18 s) |
| Sprite table = `webamp_sprites.json` (212) except documented overrides | `SpriteTableTests` | **GO**: 212/212 identical, overrides: none (`docs/spikes/sprite-overrides.md`) |
| Webamp fixtures: 7 region, 4 viscolor, 4 pledit | `ParserTests` | **GO**; region output compared with Webamp's own snapshot file |
| Marquee stepOffset/loopText, slider, layout, hit-test tests | `MarqueeModelTests`, `SliderGeometryTests`, `LayoutTests` | **GO** |
| snapUtils.test.ts cases on pure geometry | `SnapGeometryTests` | **GO** (all Webamp cases; live WindowManager part is M5) |
| Zip bomb: 1 MB archive, 1 GiB entry, peak RSS < 150 MB | `sudamp-dev skin-fuzz --make-bomb /tmp/bomb.wsz`, then `/usr/bin/time -l sudamp-dev skin-load /tmp/bomb.wsz`; test `swift test --filter ZipBomb` | **GO**: 1,043,879-byte archive, `entryTooLarge`, exit 3, **13.5 MB** max RSS; the test's footprint check also passes |
| skin-fuzz 2000 mutations, 0 crashes | `sudamp-dev skin-fuzz Fixtures/skins --mutations 2000` | **GO**: debug build, default seed 6136753: 0 crashes, 1,100 loaded, 900 rejected, 5,500 window renders, 173 s, 53 MB peak RSS; release, seed 2: 0 crashes, 1,091/909, 13.7 s, 71 MB |
| Two skingen runs byte-identical and equal to the committed skin | `skingen --check Fixtures/skins/sudamp-dark.wsz` (+ `SudampDarkTests`) | **GO**: 19,355 bytes, SHA-256 `139b75ea71dd3b0842436d6962775195d5acf8fe41658b912f4c9e885dafa1ec`; `unzip -t` clean |
| Exported skin reloads and renders identically | `SudampDarkTests.exportedSkinReloadsAndRendersIdentically` | **GO** (all 5 windows) |
| Render goldens via CLI | `sudamp-dev render --skin <wsz> --window … --state Fixtures/states/<n>.json --out /tmp/x.png` | **GO**: all 13 sudamp Dark + 4 AndAmp Dark SHA-256s equal `goldens.json`; `.rgba` hashes to the `.sha256` value |
| CJK title → `marquee.fallback == "system"`; "always skin font" → transliterated | states 06/07, `GoldenRenderTests.cjkTitleSwitchesToTheSystemFont` | **GO**: `[lofi] 東京の夜 …` → system; with alwaysSkinFont → `[lofi] dong jingno ye - rofai` |
| Zero new warnings, escapes justified | clean build of SkinKit, SkinKitTests, skingen, sudamp-dev into a throwaway scratch path + `scripts/check-warnings.sh`; `scripts/count-escapes.sh` | **GO**: only the allow-listed CLT `ld` search-path warnings; 0 concurrency escapes |
| `make skin-check` | needs a Makefile target (requested) | NOT-RUN as a make target; the underlying `skingen --check` passes |
| `make golden` (≈100 museum skins) | needs network + Makefile target | NOT-RUN (tracked, not a gate) |

## Measurements (release build, `sudamp-dev render --bench 200`)

| What | Time |
|---|---|
| Compose Main (sudamp Dark, playing, spectrum) | 0.150 ms |
| Compose Main shade | 0.025 ms |
| Compose EQ | 0.105 ms |
| Compose Playlist (6 rows) | 0.290 ms |
| Compose Main (AndAmp Dark, region applied) | 0.137 ms |
| Load AndAmp Dark (.wsz → Skin, fallback already built) | ~1.9 ms |
| First load incl. generating sudamp Dark in memory (`report.loadMillis`) | 14.2 ms (AndAmp), 4.3 ms (sudamp-dark.wsz without fallback) |

## Design decisions and deviations (all deliberate, all tested)

- **Pixels are copied, not drawn.** Sheets are normalised once through a CGContext (sRGB, premultiplied over
  black, then forced opaque: "alpha ignored"); after that the composer, rasteriser and generator only copy integer
  pixels in `Bitmap`, so frames and the generated `.wsz` are byte-identical on any macOS version.
- **The generator owns its DEFLATE.** `Zip/Deflate.swift` (greedy LZ77, one fixed-Huffman block) makes skingen's
  output independent of the system zlib; Compression only inflates. 866 KB of BMPs zip to 19 KB.
- **Fallback skin without a resource.** `SudampDark.skin` is generated in memory on first use (~10 ms release), so
  SkinKit needs no `resources:` entry; the committed `Fixtures/skins/sudamp-dark.wsz` is proven identical by test.
  Rejected archives never build it (the fallback argument is an autoclosure).
- **Caps.** 32 MiB per entry (declared uncompressed and compressed, and inflation is bounded by the declared size
  plus one byte), 96 MiB summed over the entries actually extracted, 512 entries (from the end record, before
  parsing), 128 MiB per archive file (stat before read), 2048 px per sheet side (from the image header). Only
  whitelisted entries are ever inflated. Zip64, multi-disk and encrypted entries are refused; CRCs are not checked
  (JSZip, hence Webamp, does not either). An archive with no skin file at all is rejected as `notASkin`.
- **Matching.** Webamp's regex treats the dot before the extension as any character; SkinKit requires a real dot.
- **Region semantics.** Webamp's parser (partial polygons kept, counts < 3 skip points, continuation lines ignored
  as Winamp's single-line profile reads do); macamp's parser was evaluated but not used. Polygons are filled
  even-odd one by one and unioned, matching Webamp's SVG clipPath (overlapping-rectangle files like Satellite M
  would cancel out in one even-odd pass). Coordinates beyond ±1e9 are ignored.
- **Text.** Deburr follows lodash's letter table and also strips combining marks from all Latin (`Ș` → `S`); curly
  quotes and dashes fold to ASCII first. A title needs the system font only when a non-ASCII character has no glyph;
  unmapped ASCII (`~`, `|`) draws blank as in Webamp.
- **Clock.** Past 99:59 the main display shows hours:minutes (Bitamp's rule; Webamp would draw blank digits),
  because radio sessions run for hours. Live streams (no duration) have no position thumb and no remaining time.
- **EQ graph.** Webamp draws the preamp line lower as preamp rises; SkinKit moves it up like the bands.
- **Playlist rows** use the built-in original pixel font in pledit.txt colours, so the 1x frame is deterministic;
  DESIGN §8.3's Core Text rows are an overlay for SkinUI at ≥ 2 device px (`metadata.playlistFallback` flags rows
  that need it). Titles are transliterated for the pixel font.
- **Layers.** `RenderOptions.drawDynamicLayers = false` leaves the marquee text and visualiser out of the base
  frame; `WindowComposer.marqueeLayer` and `visualizerLayer` produce them separately (tested: base + layers ==
  full frame), matching DESIGN §8.1's sublayer plan.
- **Layout.** Effective Webamp draw rects: next 22 wide, shuffle 46, work indicator 3x9, shade transport from
  x=169, shade mini time at 128/134/139/147/152, volume thumb travel 51 (65 px input), balance 24, position 219,
  EQ thumb 51. Title-bar buttons have no sprite until pressed (the title bar bitmap carries them), as in Webamp;
  sudamp Dark therefore paints them into its title bars (Bitamp's writer did not).
- **sudamp Dark art.** Bitamp's DefaultSkin drawing code with a new palette only: near-black panels (#15171A),
  graphite bevels (#3A3F46/#050607), teal accent #14B8A6 with #0D9488, title `SUDAMP`, an original "S" about mark,
  new art in the same style for sprites Bitamp never drew (clutter bar, work indicator, playlist menus, …). No
  Nullsoft pixels; no Bitamp text in any sheet (tested); readme.txt credits Bitamp and Webamp.

## Not done / open

- **Shared changes pending** (requested from the orchestrator): a `skin-check` Makefile target, PROVENANCE.md /
  THIRD_PARTY_NOTICES entries, and (optional) a `make golden` target.
- **Not implemented:** playlist shade and resizing (v1 is fixed 275x232), gen.bmp/genex windows, `.cur`/`.ani`
  cursor decoding (cursors are matched and reported only), double-size beyond uniform scaling (SkinUI), the easter
  egg title bars, `make golden` against museum screenshots (needs ~100 downloads; not attempted, no network use).
- **Unverified:** whether Winamp itself unions region polygons or uses one winding pass (we follow Webamp);
  magenta colour-keying (DESIGN §8.2: follow Webamp, none); the exact 1-px vertical placement of the EQ-shade thumbs
  (browsers centre a 7 px thumb in a 6 px input; SkinKit uses y=4).
- **AndAmp Light** is committed as a fixture (with credits) but has no goldens yet.
- **Owner decision:** sudamp Dark's readme states GPL-3.0-or-later for the skin art (generated by GPL code from
  MIT-derived routines); a more permissive art licence (e.g. CC BY 4.0) is possible if preferred.

## How to regenerate

```
python3 -I scripts/gen-sprites.py            # needs the pinned Webamp clone in /tmp/sudamp-priorart (see script)
python3 -I scripts/gen-sprites.py --check    # CI-safe only where the clone exists
swift run skingen                            # rewrites Fixtures/skins/sudamp-dark.wsz
swift run skingen --check Fixtures/skins/sudamp-dark.wsz
SKINKIT_UPDATE_GOLDENS=1 swift test --filter GoldenRenderTests   # after an intended rendering change; review the diff
```
