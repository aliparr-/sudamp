# Museum golden metric (PLAN M4/M7 skin compatibility; tracked, not a gate)

*2026-10-22 · agent: polish · scratch path `.build-polish` · macOS 27.0.1, M5 Pro, CLT only, Swift 6.4*

**Result.** Over 100 complete Skin Museum skins, SkinKit's Main window is within 0.5% differing pixels of Webamp's
museum screenshot for **100 of 100** skins (93 pixel-identical outside the masks). With the EQ window included the
share is **21 of 100**, and every one of the 79 misses is the same single, deliberate difference: SkinKit draws the
EQ graph's preamp line *up* as the preamp rises, Webamp draws it *down*. With that line masked, Main and EQ are both
within 0.5% for **100 of 100** skins (13 pixel-identical in both windows). Getting there found and fixed two SkinKit
bugs (16-bit BMP colours; holes punched by short `eqmain.bmp` sheets), one latent one of the same kind, and two
errors in the harness's idea of the screenshot state. All existing render and app goldens are byte-identical.

## How it works

| Piece | What it does |
|---|---|
| `scripts/golden-fetch.sh` | Lists the museum through its GraphQL API (`POST https://api.webamp.org/graphql`, no auth): 16 pages of 50 spread evenly over all 104,352 skins, keeps non-NSFW skins whose `archive_files` hold every sheet Main, EQ and Playlist draw (`main cbuttons titlebar shufrep posbar volume balance monoster playpaus text eqmain eq_ex pledit` plus `numbers` or `nums_ex`, any folder, `.bmp` or `.png`), takes the first 7 per page, pins the 100 in `manifest.json`, and downloads each `.wsz` and its 275x348 screenshot from `r2.webampskins.org`. One request at a time, 1 s apart, User-Agent `sudamp-dev-golden/0.1 (…)`, everything cached; a 403 or 429 stops the run. Cache: `~/Library/Caches/sudamp-dev/golden/` (never the app's folders; the script refuses them). |
| `Tests/SkinKitTests/MuseumGolden.swift` | The logic, unit-tested (state, masks, comparison, attribution, PNG decoding with alpha), plus `MuseumGoldenHarness`, which only runs with `SKINKIT_GOLDEN=1`: loads each skin with `SkinLoader`, renders Main and EQ with `WindowComposer` in the screenshot state, compares them with the screenshot crops (Main y 0–115, EQ y 116–231) and writes `report/summary.md`, `report.json`, `heat-main.png`, `heat-eq.png` and `strips/<worst %>-<md5>.png` (screenshot, SkinKit, differences in red, 2x). |
| `scripts/golden-compare.sh [--scratch-path P]` | Builds only `SkinKitTests` and runs the harness from that build, then prints the summary. Requested as `make golden` (fetch + compare). |

**Comparison rule.** A pixel is compared unless masked. It differs when one side is opaque and the other is not
(alpha ≥ 128 counts as opaque, since Webamp's SVG clip path anti-aliases region edges), or when both are opaque and
any channel differs at all (a second figure allows 2/255). Both transparent is a match. A skin passes when Main and
EQ each differ in at most 0.5% of their compared pixels (144 of Main's 28,961, 159 of EQ's 31,900).

**Scored only when complete.** A skin is scored only if neither window drew a sheet from the fallback skin
(`RenderMetadata.fallbackSheets` empty): where a skin lacks a sheet Webamp drew Nullsoft's base skin and SkinKit
draws sudamp Dark. All 100 selected skins loaded (0 rejected, 0 crashes) and all were complete.

**Screenshot state** (`MuseumScreenshot.state`). Webamp's `packages/webamp-demo/js/screenshotInitialState.ts` @
`7734cd3` (unchanged since 2018) on top of its reducer defaults: playing, 3 s into a 5 s track, 128 kbps, 44 kHz,
stereo, volume round(200/255·100) = 78, balance 0, EQ on with sliders 52 74 83 91 80 54 23 19 34 75 and preamp 56,
Main focused (EQ title bar inactive), EQ and Playlist open. **Correction found by the metric:** the screenshots show
shuffle, repeat and EQ auto *selected* (98 of 100 skins; e.g. Ancient Egypt's salmon `shufrep.bmp` row y=30, and
"auto" instead of "manual" on Heaven & Earth), although the state file and Webamp's reducers default all three to
off. The harness follows the screenshots.

**Masks** (docs/research/findings-skins.md): the visualiser (24,43 76x16, live in screenshots), the marquee text
and the clock (38,26 61x13, both minus positions and four digits). The marquee mask is **155 px** wide (111,27
155x6), one more than SkinKit's 154: Webamp's marquee was 155 px until 2021-04-30 (captbaritone/webamp `309c2710`
"Fix marquee width") and most screenshots are older, so the 155th column shows text in 53 skins. SkinKit's 154
matches current Webamp and is not changed. The masks cover 2,939 of Main's 31,900 pixels (9.2%); EQ is unmasked.

## Numbers

| Step | Both ≤ 0.5% | Main ≤ 0.5% | EQ ≤ 0.5% | Both, preamp line masked | Pixel-identical (both) |
|---|---|---|---|---|---|
| Baseline: state as in `screenshotInitialState.ts`, 154-px marquee mask | 7 | 37 | 10 | n/a | 0 |
| Harness: shuffle, repeat, EQ auto as the screenshots show them | 21 | 95 | 21 | 95 | 3 |
| + 155-px marquee mask (harness) and SkinKit's 16-bit BMP decoder | 21 | **100** | 21 | **100** | 5 |
| + SkinKit: no transparent EQ-curve pixels from a short `eqmain.bmp` | **21** | **100** | 21 | **100** | **13** |

Final run: median differing share Main 0.00%, EQ 0.65% (the preamp line); allowing 2/255 per channel, 28 of 100
pass both (the extra seven are region-edge colour rounding). Largest remaining difference outside the preamp line:
20 pixels (Main), 15 (EQ). Run time 33–37 s for 100 skins (debug build). SkinLoader timing in that debug build:
p50 4.3 ms, p95 6.5 ms per skin, max 891 ms (the first load, which also generates sudamp Dark).

Corpus: 100 skins, 104,352 in the museum; 10 carry region.txt (9 shape Main, 8 the EQ); 5 ship 16-bit sheets (30
sheets); sheet formats 24-bit 1,256, 32-bit 52, 8-bit 51 (+31 RLE8), 16-bit 30, 4-bit 2. 217 requests to the museum
(17 GraphQL, 200 downloads), 0 failures, 28 MB cached.

## Triage of systematic differences

| # | Difference | Skins | Cause | Class | Action |
|---|---|---|---|---|---|
| 1 | Shuffle, repeat and EQ auto drawn in the other state | 98 | Screenshots were taken with all three selected | harness | State fixed in the harness |
| 2 | Whole windows off by up to 46 levels (whites at 248) | 5 | ImageIO widens 16-bit (5-5-5) BMP channels by shifting, v<<3; browsers scale, round(v·255/31) (31 → 255, 3 → 25; measured on MAGiC.wsz) | **SkinKit bug** | `Image/BMP16Decoder.swift`: decodes 16-bit BI_RGB and BI_BITFIELDS sheets itself with Skia's scaling; everything else still goes to ImageIO |
| 3 | 139 transparent pixels along the EQ curve | 8 | `eqmain.bmp` is 164 px tall, so the 1x19 graph-colour strip at y=294 lies outside the sheet; SkinKit painted the curve with those out-of-sheet (clear) colours and punched see-through holes. Webamp's pattern from an empty sprite draws nothing | **SkinKit bug** | `EQGraph.draw` skips transparent colours (test: `GoldenTriageTests`) |
| 3b | (latent, same class) text.bmp narrower than 153 px gives a transparent text background, so the system-font marquee field would be see-through | 0 in corpus | `Skin.textColorsOf` sampled outside the sheet | **SkinKit bug** | Falls back to the fallback skin's text colours (test) |
| 4 | Column x=265 of the marquee rows | 53 | Webamp's marquee was 155 px wide until 2021 | screenshot era | Mask widened by 1 px; SkinKit unchanged |
| 5 | Preamp line two rows off (rows 8 vs 10 of the graph at preamp 56) | 87 (of the other 13, 9 have no preamp-line row: `eqmain.bmp` 164 or 314 px tall; 4 draw it in the same colours as the graph rows it lands on) | SkinKit moves the line up as the preamp rises, like the bands (M4 decision, `EQGeometry.swift` header); Webamp maps preamp 100 to the bottom row | **deliberate** | Kept. Reported raw and with the line's rows masked. Changing it would rewrite goldens `sudamp-dark/09-eq-curve`, `10-eq-off-pressed` and app `10-eq-off-custom-2x` (preamp 62, 0, 3); decide against real Winamp 2.9x before M9 |
| 6 | 9–20 pixels at rounded window corners, 2 of them opacity | 7 | region.txt: SkinKit fills polygons GDI-style without anti-aliasing (DESIGN §8.2, spike S1); Webamp's SVG clip path anti-aliases diagonal edges | expected | None (Webamp is not a reference for which edge pixels are covered) |

No other systematic difference remains: no control differs in more than 7 skins once 1–5 are accounted for, and the
hot-spot list (pixels differing in at least 25% of skins) contains only the preamp-line rows.

## Goldens and tests

- `GoldenRenderTests.rgbaHashesMatchGoldens` passes unchanged (sudamp Dark 13 states, AndAmp Dark 4): all fixture
  skins are 24-bit and have full sheets, so none of the fixes can touch them. The app snapshot goldens
  (`Fixtures/states/app`) are checked by the full suite (see the final report).
- New tests: `BMP16Tests` (8: museum-measured levels, row order and padding, 5-6-5 bitfields, Skia's 5-bit table,
  fallbacks to ImageIO, short data, oversized header, 3,000 seeded corruptions), `GoldenTriageTests` (4), `MuseumScreenshotStateTests` (4),
  `GoldenCompareTests` (7). The EQ regression test was checked to fail with the fix reverted.
- `swift test --filter SkinKitTests`: 127 tests in 28 suites pass (~19 s).

## Open

- **Preamp-line direction** (row 5): the only thing between 21% and 100%. Evidence from real Winamp is needed, not
  Webamp; the owner decides.
- The corpus is complete skins only, by design; incomplete skins exercise the fallback path, which no screenshot can
  judge. Magenta colour-keying (MacAmp issue #84) and `sudamp-dev skin-bench` (release load times) remain M7 items
  outside this metric; the debug-build load figures above are indicative only.
- Screenshots are Webamp renders from different years; the harness encodes two screenshot-era facts (toggle state,
  155-px marquee). If the museum re-renders its screenshots, rerun with `golden-fetch.sh --refresh` after clearing
  `screenshots/`.

## Reproduce

```
scripts/golden-fetch.sh                      # ~4 min the first time; cached afterwards
scripts/golden-compare.sh --scratch-path .build-polish
open ~/Library/Caches/sudamp-dev/golden/report/strips   # worst first by file name
```
