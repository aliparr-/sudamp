# Measurements

Numbers measured on the dev machine (macOS 27.0.1, Apple M5 Pro, Command Line Tools only), appended per milestone. Live network numbers are from one UK residential connection and vary day to day.

## M0 (2026-10-22)

### Engine (E1, E2, L1)

- E1 release bench (final): shortReads 0; pauseToSilenceMs max 14.81 / p50 8.99 (design bound 15.67 = 10.67 ms IO buffer + 5 ms ramp); pause takes effect ≤ 9.81 ms; mpv-only pause 4.3-10.0 ms; resume ≤ 8.3 ms with a 0.20 ms source gap; seek p50 4.44 / p95 10.83 / max 10.83 ms, 0 stale quanta; loadfile p50 7.14 / max 12.79 ms; first load 3.5 ms; get_property p50 0.003 / p99 0.024 / max 0.144 ms; CPU 1.03% of one core
- E1 repeatability (release, 30 s): pauseToSilence max 14.86 / 14.52 / 14.62 / 14.81 ms; seekP95 11.07 / 10.88 / 10.80 / 10.83 ms; loadfile max 9.46 / 14.29 / 9.96 / 12.79 ms; CPU 1.41 / 1.08 / 1.39 / 1.03 %
- Callbacks: all 512 frames, mean interval 10.667 ms, max 10.73 ms; presentationLatency 11.917 ms = output 1.25 + IO buffer 10.667
- Selftest (app, fixture): TTFA 8.8 ms at the render callback; audio-params 44100 Hz → audio-out-params floatp/48000/stereo
- Radio TTFA (SomaFM HTTPS, render callback): 862 ms with radio options (reconnect_streamed=1); 2.46 s once with request_size/short_seek_size added (single sample); L1 60 s run 862 ms (earlier 809 ms)
- stress-lifecycle: about 97 ms per create/play/destroy iteration; RSS 12 → 82 MB after 4 iterations (one-time), then about +0.12 MB per iteration (105 MB after 200); threads flat at 7-8
- E2: switch → audio p50 169-170 ms, p95 223 ms, max 493-495 ms (first move, after a self-inflicted notification about 320 ms after the toggle); moves to the aggregate 205-230 ms; returns to the built-in 155-170 ms; mpv API p99 0.026-0.027 ms
- Wire check (local nc): http-header-fields with escaped commas arrive as single headers; the UA keeps its commas

### Resolver and yt-dlp delivery (R1)

- yt-dlp 2026.10.21 onedir install, fresh profile: 53,879,210-byte zip download 970 ms, ditto unpack 180 ms, tree.json of 134 files / 128.8 MB 58 ms, cold --version 1552 ms, warm --version 164-169 ms, total 4.0 s
- Live Range resume: truncated .partial of 20,000,000 bytes, Range request answered with HTTP 206 via the release-assets.githubusercontent.com redirect, rest fetched in 670 ms, SHA match
- engine status tree re-hash: 57-60 ms for 134 files
- Warm resolve, YouTube VOD tier 1 (bk6Xst6euQk): p50 1513 ms, p90 1545, min 1219, max 1696 (n=10)
- Warm resolve, YouTube /live (@LofiGirl): p50 2368 ms, p90 2678, min 2117, max 2741 (n=10)
- Warm resolve, SoundCloud (Boiler Room DJ Flight): p50 582 ms, p90 856 (n=10); without soundcloud:formats=hls_aac p50 632 ms, p90 685 (noise; same 5 requests and same 2 formats)
- Warm resolve, Mixcloud (gelka): p50 1004 ms, p90 1243 (n=10); NTS hls-192 single resolve 1122 ms
- Warm resolve, YouTube tier 2 QuickJS (VOD): p50 3596 ms, p90 3923, min 2948, max 3932 (n=10); single cold tier-2 run 3663 ms
- Nightly 2026.10.21.233146 install: 134 files, cold --version 1375 ms, warm 173-174 ms
- Subprocess kill precision: 2 s timeout fired at 2.003 s (unit test); live black-hole proxy resolve killed at 10,003 ms and classified transient/timeout
- URL expiry from resolve: YouTube VOD and /live +6.0 h; SoundCloud +2.8 h; Mixcloud none
- YouTube requests used: 38 of 40 (1 search, 11 tier 1, 11 live, 11 tier 2, 2 error captures, 2 raw-JSON captures), all at least 3 s apart; no bot check seen

### Starter catalog curation

- yt-dlp 2026.10.21 (latest, published 2026-10-21T21:54:37Z): yt-dlp_macos.zip is 53,879,210 bytes and its SHA-256 matches upstream SHA2-256SUMS; cold --version took 4.45 s wall right after unpacking
- Radio probes (32 KB each, twice): 10/10 HTTP 200 audio/mpeg. Redirects: deep.radio → 22603.live.streamtheworld.com:443; technolovers.fm → 0nlineradio.streamNN.radiohost.de; sunshine-live → sunsl.streamabc.net; rautemusik → rautemusik.streamNN.radiohost.de; reyfm → reyfm.streamNN.radiohost.de
- SoundCloud api-v2 checks: 10/10 items have policy MONETIZE or ALLOW, |duration − full_duration| from 4 ms to 697 ms, non-snipped aac_160k/aac_96k HLS; media host playback.media-streaming.soundcloud.cloud
- Mixcloud: 10/10 resolved through yt-dlp with no restrictedReason. Media hosts: aod.mixcloud.stream (HLS/DASH), dl.mixcloud.stream (progressive http). Older uploads offer only hls-64/6x, not hls-192
- YouTube tier-1 (visionos, no JS runtime): 3/3 VODs public with itag 251, ~7.4 s wall each including the deliberate 3 s request sleeps, so not a TTFA figure. 4/4 /live handles is_live with audio-only HLS itag 234
- Test runtime: PickerTests 0.09 s (includes the 10k-draw χ² tests), CatalogTests 0.02–0.03 s, FeedsTests 0.01–0.02 s

### SkinKit (M4, built early)

- Release, `sudamp-dev render --bench 200`: Main 0.150 ms, Shade 0.025 ms, EQ 0.105 ms, Playlist 0.290 ms (sudamp Dark); AndAmp Dark Main with region 0.137 ms.
- Skin load, release: AndAmp Dark ~1.9 ms once the fallback is built; first load including generating sudamp Dark in memory 14.2 ms (report.loadMillis); sudamp-dark.wsz with no fallback 4.3 ms.
- Zip bomb: 1,043,879-byte archive, 1,073,741,824-byte declared entry, rejected entryTooLarge; max RSS 13.5 MB (/usr/bin/time -l, debug build).
- skin-fuzz 2000, debug: 0 crashes, 1100 loaded / 900 rejected, 5500 renders, 173 s, 53 MB peak RSS. Release, seed 2: 0 crashes, 13.7 s, 71 MB.
- sudamp Dark: 866,765 bytes of sheets and text deflate to a 19,355-byte .wsz with SkinKit's own encoder (17 files).

### Spikes S1 and R2

- S1 WindowServer hit test (1x display, screen locked, 7 windows above the probe excluded), ignoresMouseEvents never assigned: bodyOpaque/islandOpaque → shaped; notch / corner-cut alpha 0 → lower window; notch with lower window hidden → another process's window (layer 0). Assigned false: all 5 spots → shaped. Assigned true: all → lower. Getter reads false for both 'never assigned' and 'false'.
- S1 live content change on one never-assigned window, notch spot: full → shaped, notched → lower, full → shaped, notched → lower.
- S1 in-process dispatch: hitTest override on → content view gets no mouseDown at the alpha-0 spot (opaque spot still delivered); WindowServer target unchanged.
- S1 shadow alpha 6 pt below the bottom edge: 18 under solid parts, 0 under the notch (after a mask change, with or without invalidateShadow()). Inside the notch below its top edge: 23, 6, 1, 0 (4-px steps). Inactive-window shadow only.
- S1 tests: 20 pass in about 0.11 s; brute-force reference agrees on 800 random polygons.
- R2 downloads: PBS 3.14.9 install_only_stripped 26.7 MB; 3.13.17 25.3 MB; yt-dlp 2026.10.21 zipapp 3,074,818 B (SHA-256 matches SHA2-256SUMS); onedir zip 53.9 MB.
- R2 unpacked: PBS 3.14 68.8 MB (1,691 files, 10 Mach-O); 3.13 65.4 MB. Trimmed 3.14 28.7 MB (10.1 MB tgz); trimmed + stdlib unchecked-hash pyc 39.5 MB (14.0 MB tgz, 1,060 files, 2 Mach-O). Zipapp unpacked 11.8 MB, with checked-hash pyc 24.5 MB (2,101 files). Onedir 123.1 MB, 134 files, 107 Mach-O.
- R2 --version, scrubbed env, warm p50 of n=10:
- 3.14 -I -B zipapp: 425 ms (first 611)
- 3.14 pycache_prefix + zipapp: 242 ms (first 451)
- 3.14 pycache_prefix + unpacked tree: 65 ms (first 371)
- 3.13 equivalents: 393 / 227 / 62 ms
- trimmed + pyc, -B, read-only: 67 ms (first 68)
- trimmed + pyc, zipapp file: 243 ms
- onedir: 165 ms (first 1,592)
- R2 warm resolves (DESIGN §6.2 flags), p50 of n=5, first run in brackets:
- SoundCloud: plan-B tree 493 ms (661), zipapp file 906 (1,192), shipping shape 532 (759), onedir 561 (734)
- Mixcloud: tree 675 (951), zipapp 1,120 (1,518), shipping shape 770, onedir 858 (785)
- YouTube visionos JS-less (n=1): 1,288 ms, itag 251, range GET 206
- R2 TLS: PBS OpenSSL 3.5.9 default cafile /private/etc/ssl/cert.pem (128 roots); out of the box OK; expired and self-signed badssl.com rejected; SSL_CERT_FILE=/nonexistent → CERTIFICATE_VERIFY_FAILED, also in yt-dlp; certifi 2026.10.19 picked up by yt-dlp when importable.
- R2 hardened runtime: ad-hoc --options runtime python3.14 resolved SoundCloud (646 ms); built with --enable-experimental-jit=yes-off, so no allow-jit needed.

### Integration: first audio per source (orchestrator, 2026-10-22)

`sudamp-dev play-url --resolved .build-resolver/r1/resolved-<source>.json --seconds 8 --json`, debug build, silent. Time from `loadfile` to the first non-silent sample at the render callback, using URLs resolved earlier by R1:

| Source | Format | First audio | Short reads | AO params |
|---|---|---|---|---|
| YouTube VOD | itag 251 (webm/opus, progressive, 10 MiB ranges) | 190 ms | 0 | floatp/48000/stereo |
| YouTube `/live` | itag 234 (HLS audio-only) | 574 ms | 0 | floatp/48000/stereo |
| SoundCloud | hls_aac_160k | 1,790 ms | 0 | floatp/48000/stereo |
| Mixcloud | progressive `http` 64k | 894 ms | 0 | floatp/48000/stereo |
| Mixcloud | HLS | 1,619 ms | 0 | floatp/48000/stereo |

Implication: a cold pick is resolve + open. With the R1 resolve p50s that gives about 1.7 s (YouTube VOD), about 2.9 s (`/live`), about 2.4 s (SoundCloud, over its 2.0 s target) and about 1.9 s (Mixcloud). SoundCloud's HLS open is the slowest step; M1 measures the end-to-end number with `sudamp-dev ttfa`, and prefetch hides it for every pick after the first.

- L1 engine spawn from the hardened ad-hoc app (`sudamp --selftest --engine-check`): yt-dlp 2026.10.21 `--version` cold 220 ms, warm median 164 ms; no code-signing, library-validation or JIT messages in `log show` beyond amfid's standard ad-hoc `Code=-423` notice.


## M3 audio (audio agent, 2026-10-22)

Details and decisions: `docs/spikes/M3-audio.md`; device changes before/after: `docs/spikes/E2.md`. macOS 27.0.1, M5 Pro, Mac mini Speakers (48 kHz, 512-frame IO buffer, presentation latency 11.917 ms). All inaudible (offline renders; live runs at mixer volume 0).

- `eq-selftest` (offline manual rendering of the real graph; AVAudioSourceNode renders offline): bands 0–9 at +12 dB read 12.0000 dB at their centres; preamp +6 → 6.0000; flat 0.0000 at all ten centres; balance full left: right -352 dB (exact zero), left 0.0000; EQ off with +12 everywhere: 0.0000. Analytic RBJ (prewarped) model vs the unit, 17 presets × 16 frequencies: max error < 0.00005 dB. 253.5 s of audio rendered in ~2 s (debug).
- `eq-selftest` persistence (live, muted, mpv, ramp fixture's 1 kHz left channel, band 4 at +12): 12.0000 dB before, after `loadfile`, after seek; mixer output peak 0.
- Shelf A/B at +12 dB: parametric 60 Hz reads 1.00 / 2.52 / 12.00 / 1.13 dB at 20 / 30 / 60 / 170 Hz, low shelf 11.81 / 11.10 / 6.00 / 0.24; parametric 16 kHz reads 4.23 / 8.41 / 12.00 / 6.55 dB at 8 / 12 / 16 / 20 kHz, high shelf 0.19 / 1.47 / 6.00 / 11.31. Kept parametric.
- AUPeakLimiter (after the EQ): latency = attack (2 ms default; 0.5 ms min; 12 ms tried); bit-exact below full scale (null ≤ -291 dB at -20/-6/-1 dBFS noise); a +6 dB sine overload loses 9.0–13.4 dB (peaks -3.1 to -7.4 dBFS); bass-boost IMD -17.1 dB (0.5 ms), -26.6 dB (2 ms), -140.9 dB (12/24 ms); CPU +0.002–0.008 % of a core (reference chain 0.17 %). Device hard clip of the same overloads: THD -12.6 dB, IMD +1.3 dB. +6 dB cap (shipped): peak -0.02 dBFS, THD -163 dB; bass boost IMD -142.6 dB, peak +0.19 dBFS. Not shipped.
- Visualiser analyser: 0 heap allocations in 1000 analyses (malloc_logger count, debug and release); a -20 dBFS sine reads -20 ± 0.5 dB in its bar; ring stress: 30,000 × 512-frame callbacks (15.4 M frames) against a concurrent reader, 0 torn reads.
- `devswitch --cycles 20`, final engine, two runs: 40/40 and 40/40 audible ≤ 500 ms; p50 125.6 / 124.1 ms, p95 241.8 / 245.7, max 249.8 / 249.1; first move 228.0 / 242.0 ms (baseline 464.9; E2 494.8 / 493.1); return to built-in median 106.3 / 104.9 ms (baseline 160.2), not paused; silence per switch ~77 ms (baseline 219 → aggregate, 160 → built-in); 0 self-inflicted configuration changes; mpv API p99 0.030 / 0.027 ms; RSS 92 → 82 MB.
- `bench-transport` (release, 30 s), two runs: shortReads 0 / 0, pauseToSilence max 15.42 / 14.36 ms (p50 11.92 / 9.13), seekP95 10.89 / 10.70 ms, stale quanta 0 / 1, loadfile max 12.88 / 12.11 ms, getProperty p99 0.059 / 0.059 ms, CPU 1.45 / 1.48 %.
- `stress-lifecycle 100` (release): 100/100, 0 crashes, 0 failures; RSS 12.3 → 100.9 MB (a pre-M3 binary: 12.2 → 98.3 MB; one earlier run under load: 156.8 MB, 104 ms/iteration).

## M1 thin slice (playback agent, 2026-10-22)

End-to-end through `PlaybackController` (`sudamp-dev play | ttfa`, debug build, silent: mixer 0 and bridge output zeroed after the TTFA stamp). TTFA runs from the user action (genre pick, Next) to the first non-silent sample at the render callback. yt-dlp 2026.10.21 from the feed's pin. Details: `docs/spikes/M1.md`.

- `play --genre deep-house --seconds 120 --next-every 20`: 6 streams started, 0 failures, 0 unhandled errors, 0 short reads. Cold first pick (Mixcloud) 3145 ms; prefetched picks 462 (YT /live), 232 (YT), 112 (YT), 513 (MC), 1346 ms (MC), so prefetched p50 462 ms
- `ttfa -n 3`, cold picks (no prefetch, cache cleared before each run):
- radio (HTTPS): 702 / 1849 / 403 ms, p50 702 ms (target ≤ 1500)
- radio over plain http://: 1103 / 1805 / 402 ms, p50 1103 ms (target ≤ 1500)
- SoundCloud: 1534 / 1581 / 1588 ms, p50 1581 ms (target ≤ 2000); resolve 574–666 ms, so the HLS open takes about 0.95 s
- Mixcloud: 1771 / 2672 / 1599 ms, p50 1771 ms (target ≤ 2500); resolve 669–1363 ms
- YouTube VOD: 1821 / 1525 / 1879 ms, p50 1821 ms, p90 1879 ms (target ≤ 3000 / 3500); resolve 1431–1755 ms
- YouTube /live: 2600 / 3115 / 3840 ms, p50 3115 ms, p90 3840 ms: **misses** ≤ 3000 / 3500. Resolve 2199 / 2278 / 3184 ms, HLS open 0.4–0.8 s
- `--no-engine` (radio only): 6 starts 748–1668 ms, p50 1351 ms (target ≤ 2000). Prefetching radio doesn't shorten its start (about 1.35 s either way)
- First launch with `--install-engine=true` on a fresh profile: radio first audio 1691 ms while the pinned engine installed in 3391 ms; the following SoundCloud/Mixcloud picks took 1584–2497 ms
- Live pause (radio): a 45 s pause (47.8 s actual) reloads at the live edge and is audible 1385 ms after resume; a 10 s pause resumes in place, audible after 12.5 ms
- Tier 2 (QuickJS-NG 0.17.0, `SUDAMP_FAULT=youtube:jsless-fail`): YouTube TTFA 3637 / 3700 / 3811 ms with resolves of 3543–3641 ms. The 24 h preference started on the 2nd rescued failure. With `SUDAMP_CLOCK_OFFSET=3600`, still tier 2 (3794 ms); with `90000`, back to tier 1 (1511 ms)
- Proxy (local logging CONNECT proxy): yt-dlp `--proxy` and mpv `http-proxy` both tunnelled HTTPS with CONNECT (radio, its redirect target, www.youtube.com, manifest.googlevideo.com, rr*.googlevideo.com). The resolve through the proxy took 1468 ms, with first audio at 1565 ms
- Range probe (64 KB, progressive YouTube prefetch): HTTP 206 in 43 ms
- HLS open (SoundCloud, mpv -v): FFmpeg fetches init.mp4, data000 and data001 twice before first audio (the second time after mpv's track-selection refresh seek); `play-url` TTFA 1000 ms against a 593 ms resolve
- MPVClient event-handler thunk growth (Swift 6.4): `Mutex<closure?>.withLock { $0 }?(x)` adds 2 stack frames per call at -O and -Onone (40,000 frames after 20,000 calls), so the 512 KB event thread overflows after about 100 s of playback
- `stress-lifecycle 100`: 0 crashes
- Tests: the package has 561 Swift Testing tests (93 new from this agent); PlaybackTests take about 0.1 s and ResolverTests about 0.33 s
- YouTube requests used by this agent: 21 resolves, at least 3 s apart; no bot check

## M5 groundwork: SkinUI (2026-10-22)

- Skin preview, release, scale 2 on a 1x display, screen locked: 1.06% CPU mean over 20 s while animating (`--ignore-occlusion`: 30 Hz visualiser, scrolling marquee, 4 Hz fake state), 0.55% with the default occlusion pause; display link about 30 Hz on Main, 0 on EQ and Playlist.
- On-screen pixel exactness (own-window capture, `--verify-capture`): 0 non-uniform blocks, max channel delta 0 at 1x/2x/3x for sudamp Dark, AndAmp Dark and AndAmp Light; region.txt pixels transparent (100 per Main/EQ window, 0 leaks).

## M2 (2026-10-22)

### Plain app (`make app` debug bundle, muted)

- First launch, engine not installed (northstar-plain.json): radio TTFA 1515 / 646 / 1074 / 1159 / 1253 ms (p50 1159); final build 1251 / 646 / 625 ms. By station: 1.FM 583-646 ms, Deep Radio 1074-1412 ms, Technolovers 1159-1901 ms (redirects to another host). With vs without the concurrent engine download: 614 / 623 / 1224 vs 638 / 584 / 647 ms (n = 3 each)
- After engine install, `--skips 5` (14 s dwell): 6 starts, all non-radio: SoundCloud 2067 ms (cold first pick), then prefetched Mixcloud 1453, SoundCloud 1100, Mixcloud 1163, YouTube 114, Mixcloud 1148 ms; p50 1148, p90 2067 ms
- Engine download cut at 50% (`SUDAMP_FAULT=engine:abort-at=50`): .partial 26,951,667 of 53,879,210 bytes; relaunch resumed with Range (HTTP 206) and installed in 2.9 s
- Single instance: a forwarding second launch exits 0 in 27 ms; `.stream.id` changes 297-405 ms after a forwarded `sudamp://next` (state.json is debounced 250 ms)
- Quit path to process exit: `sudamp://quit` 128 / 353 ms, `kill -TERM` 74 / 103 / 285 ms, SIGINT 111 ms; relaunch shows `.resumed` and the genre 566-595 ms after `open`, audio about 2.3 s after `open` (Mixcloud VOD resumed at its saved position, TTFA 1.6-1.7 s)
- CPU (debug build, radio): 2.1% playing, 0.3% after 36 s paused; RSS 270 MB while playing
- YouTube requests used: 1 resolve

## M5 (2026-10-22)

### Skinned app (release bundle `build-shell5/sudamp.app`, muted, screen locked, `--ignore-occlusion`)

- CPU (`top -l 61 -s 1 -pid <pid> -stats cpu`, first sample dropped), radio, Main + Playlist, 30 Hz visualiser: playing 2.90 / 2.70 / 2.69% (mean 2.76%); paused, from 35 s after pausing, 0.36 / 0.39 / 0.38% (mean 0.38%). Before the M5 CPU work: 3.08% / 0.96%. `--plain` playing 1.87%
- North star (menu auto-opens, Deep House chosen in it): TTFA 3815 / 3386 / 3151 ms (median 3386; SoundCloud/Mixcloud cold resolves 2.2-2.8 s); earlier build 1263 / 864 / 3842 ms (median 1263)
- Forwarded `.wsz` → `.skin.id` in state.json in 343 ms; a 1 MB / 1 GiB zip bomb is refused (`skinRejected`), RSS 248 MB
- UI cost per 30 Hz frame 86 µs; marquee step 133 µs; base render 0.4 ms once a second
- YouTube requests used: 0

## M7 remote feed (feeds agent, 2026-10-22)

- Feed refresh from 127.0.0.1 (28,962-byte signed feed: fetch, Ed25519 verify, decode, cache write): 200 in 25–29 ms, 304 in 1–4 ms
- 5 s launch budget: 5265 ms with Task.sleep's default leeway; 5002–5010 ms with a 5 ms tolerance (7 runs)
- Integrated app (throwaway copy), fresh profile, feed blocking 2026.10.21: feed.fetched +33 ms, radio pick +65 ms (TTFA 1276 ms), engine.choose 2026.08.19 (pin) +129 ms, install 3.1 s; relaunch: feed.status 304 at +11 ms
- Host that never answers: engine.choose with the bundled pin +5085–5109 ms after app.launch (5.23 s warm / 5.74 s cold first exec after exec), radio TTFA 1023–1308 ms meanwhile
- `catalog-tool build --check`: 0.22 s; catalog/feed.json r2 28,938 bytes, sha256 dd2e771e…a56c3d, byte-identical after the move to catalog/genres/*.json
- `catalog-tool probe` (yt-dlp 2026.10.21): non-YouTube 20/20 (SoundCloud 570–1011 ms, Mixcloud 646–1245 ms, radio 427–1969 ms); YouTube VOD 5/5 tier 1, 1433–4256 ms, 64 KB range 206
- YouTube requests used: 5 resolves + 5 range GETs; no bot-check

## M7 golden metric and notices (polish agent, 2026-10-22)

### golden

Museum golden metric (`scripts/golden-fetch.sh` + `scripts/golden-compare.sh`; details and triage in `docs/spikes/golden.md`). 100 complete, non-NSFW skins from 16 pages spread over the museum's 104,352; Main and EQ rendered by SkinKit in Webamp's screenshot state and compared outside the masked visualiser, marquee (155 px) and clock; a skin passes when both windows differ in ≤ 0.5% of compared pixels.

- Final: **Main ≤ 0.5%: 100/100** (93 pixel-identical); **Main and EQ ≤ 0.5%: 21/100**; with the deliberate preamp-line difference masked, **100/100** (13 pixel-identical in both windows); median differing share Main 0.00%, EQ 0.65%; largest remaining difference outside the preamp line 20 px (Main), 15 px (EQ); 0 rejected, 0 incomplete, 0 crashes
- Progression (both / Main / EQ): baseline 7 / 37 / 10 → screenshot toggles corrected 21 / 95 / 21 → 16-bit BMP decoder and 155-px marquee mask 21 / 100 / 21 → short-eqmain fix 21 / 100 / 21 (pixel-identical 0 → 3 → 5 → 13)
- SkinKit fixes: 16-bit BMP channels scaled as browsers do (5 skins, 30 sheets; up to 92% of pixels before); transparent EQ-curve pixels from a 164-px `eqmain.bmp` (8 skins, 139 px each); narrow text.bmp colours (latent). Existing render and app goldens unchanged
- Remaining systematic difference: the EQ preamp line (87 skins, 2 rows of the graph), deliberate since M4; region.txt edge anti-aliasing in 7 skins (9–20 px)
- Debug build: 100 skins scored in 33–37 s; SkinLoader p50 4.3 ms, p95 6.5 ms, max 891 ms (first load, generating sudamp Dark)
- Network: 217 museum requests (17 GraphQL, 200 downloads), one at a time, 1 s apart, 0 failures; 28 MB cached in `~/Library/Caches/sudamp-dev/golden`

### notices

- `scripts/check-notices.sh`: 29 MPVKit binary targets in the link set (28 contribute objects to `sudamp`: Libavcodec 581, gnutls 302, Libshaderc_combined 241, Libmpv 217, gmp 216, Libavformat 197 …; Libssl 0); 7 system libraries; check 1–3 s; `THIRD_PARTY_NOTICES.md` 1,616 lines
- `scripts/mirror-sources.sh --verify`: 36 corresponding-source archives, 36 HTTP 200
- YouTube requests used by this agent: 0
