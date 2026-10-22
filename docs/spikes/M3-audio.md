# M3 audio: EQ, presets, balance, visualiser data, device changes (PLAN M3)

**Verdict: GO for the audio parts of M3** (2026-10-22, macOS 27.0.1, Apple M5 Pro, Mac mini Speakers at 48 kHz /
512-frame IO buffer, Command Line Tools only, Swift 6.4, MPVKit 1.0.0). Every gate below was run on the final code.
Not covered here (other agents or later): the resolver half of M3 (QuickJS tier, proxies), live/radio pause reload,
`soak`, and the Bluetooth manual checklist (E2), which needs a human with headphones.

All audio stayed inaudible: offline renders have no device; live runs keep the mixer at volume 0, and the one live
check that unmutes the render bridge (`eq-selftest` persistence) taps the mixer's output and requires it to be all
zeros (it was: peak 0). `devswitch` restored the default output (Mac mini Speakers) and destroyed its aggregate in
every run.

## Gates

| Gate | Result | |
|---|---|---|
| `swift run sudamp-dev eq-selftest --json` (debug) and release | exit 0 both; `mode: offline`; 22/22 PLAN gates and 7/7 extra checks pass; persistence `liveMuted` 5/5 | GO |
| each band +12 dB at its centre: 12.00 ± 0.1 (± 0.25 from 12 kHz) | all ten read **12.0000** | GO |
| preamp +6 → 6.00 ± 0.1; flat → 0.00 ± 0.05 | **6.0000**; **0.0000** at all ten centres | GO |
| balance full left → right ≤ -60 dB | right **-352 dB** (gain exactly 0); left 0.0000 dB | GO |
| EQ gains persist across `loadfile` and seek (live, muted, mpv) | 12.0000 / 12.0000 / 12.0000 dB before, after `loadfile`, after seek; band gains unchanged; mixer output peak 0 | GO |
| ring + analyser tests (`swift test --filter AudioTests`) | 62 tests pass (incl. 9 ring, 11 analyser, 0 allocations per analysis) | GO |
| `devswitch --cycles 20` × 2, every switch audible ≤ 500 ms incl. the first move | **40/40** and **40/40**; max **249.8** / **249.1** ms; first move 228 / 242 ms; 0 crashes, 0 failed recoveries, mpv API p99 0.030 / 0.027 ms, default restored | GO |
| `bench-transport` (release, 30 s) within M0 thresholds | 2 runs: shortReads 0/0, pauseToSilence 15.42/14.36 ms (≤ 16), seekP95 10.89/10.70, stale 0/1 (≤ 1), loadfile 12.88/12.11, getProperty p99 0.059/0.059, CPU 1.45/1.48 % | GO |
| `stress-lifecycle 100` (release) | 100/100, 0 crashes, 0 failures, AO errors 0; RSS 12.3 → 100.9 MB (pre-M3 binary: 98.3 MB) | GO |
| `make verify-binary` (runs `make build` + warnings check + `make app`) | `verify-binary: OK (_audio_out_pcm from SudampAO.o; system libraries only; signature valid)` | GO |
| `build/sudamp.app/Contents/MacOS/sudamp --selftest --json` | ok, resources ok, `mpv v0.41.0-dirty`, `sudamp pull AO`, init 1, errors 0, floatp/48000/stereo | GO |
| `scripts/count-escapes.sh` | 3 total, 0 unjustified (no new escapes) | GO |

`make test` was not run in the shared `.build`: other agents' modules were mid-edit. In `.build-audio` the whole
suite builds and every suite passes except two in-progress `PlaybackControllerTests` cases owned by the playback
agent (status text and token deferral; they use fakes, not `AudioEngine`).

## EQ

**API** (`AudioEngine`, additive): `setEQBand(_:gain:)`, `setPreamp(_:)`, `setEQEnabled(_:)` (existing), plus
`apply(_ settings: EQSettings)`, `apply(preset: EQPreset)` (bands + preamp; on/off unchanged), `eqSettings`,
`setEQHeadroom(_:)` / `eqHeadroom`, `appliedPreamp`. `EQSettings` is a Codable value (lenient decode, clamped to
±12 dB, always 10 bands) for session persistence. Gains live in the AVAudioUnitEQ, never in mpv.

**The unit is exactly an RBJ cookbook peaking cascade.** AVAudioUnitEQ's `.parametric` band matched the RBJ peaking
biquad with the bilinear-prewarped bandwidth (`alpha = sin w0 · sinh(ln2/2 · BW · w0/sin w0)`) to 0.001 dB at 21 test
points (60 Hz, 1 kHz and 16 kHz bands; the unwarped variant is off by up to 4.8 dB at 16 kHz). `EQResponse` is that
model; the selftest checks it against the real unit on all 17 presets at 16 frequencies: max error < 0.00005 dB.

**Offline rendering works.** `AVAudioEngine.enableManualRenderingMode(.offline)` renders the ObjC
`AVAudioSourceNode` (DESIGN §5.4's [unverified, M3]), so `eq-selftest` uses the real graph — `AudioEngine` in
`RenderingMode.offline`, the C render bridge fed by a deterministic C test signal (`RenderBridge.setTestSignal`) —
and needs no device. 253.5 s of audio render in about 2 s (debug). Amplitudes are I/Q fits over whole cycles after a
0.25 s settle.

### Shelf A/B (bands 0 and 9 at +12 dB; offline, real unit)

| Hz | 20 | 30 | 42.4 | **60** | 85 | 120 | 170 | 240 |
|---|---|---|---|---|---|---|---|---|
| parametric 60 Hz, 1 oct | 1.00 | 2.52 | 5.99 | **12.00** | 5.97 | 2.52 | 1.13 | 0.54 |
| low shelf 60 Hz | 11.81 | 11.10 | 9.27 | **6.00** | 2.72 | 0.90 | 0.24 | 0.06 |

| Hz | 3k | 6k | 8k | 11.3k | 12k | 14k | **16k** | 18k | 20k | 22k |
|---|---|---|---|---|---|---|---|---|---|---|
| parametric 16 kHz, 1 oct | 0.71 | 2.56 | 4.23 | 7.62 | 8.41 | 10.72 | **12.00** | 10.33 | 6.55 | 2.37 |
| high shelf 16 kHz | 0.00 | 0.05 | 0.19 | 1.08 | 1.47 | 3.24 | **6.00** | 9.15 | 11.31 | 11.96 |

**Decision: parametric at both ends** (as DESIGN §5.4). A shelf reads exactly half its gain (6.00 dB) at the
labelled frequency, failing the band-centre gate, and spends +11–12 dB of headroom below 30 Hz and above 20 kHz
(mean 20–42 Hz: shelf 10.7 dB vs 3.2 dB; mean 16–20 kHz: 8.8 vs 9.6 dB). MacAmp's shelves at 70/16k Hz remain a
v1.x option if owners prefer Winamp's "sub-bass/air" feel.

### AUPeakLimiter evaluation (offline, after the EQ; `eq-selftest --mode limiter`)

| attack / release | latency (reported = measured) | null below full scale (-20/-6/-1 dBFS noise) | +6 dB sine overload: gain reduction → peak | bass-boost IMD | CPU Δ |
|---|---|---|---|---|---|
| 2 ms / 5 ms (default) | 2.0 ms | -325 / -316 / -296 dB | 10.4 dB → -4.4 dBFS | -26.6 dB | 0.008 % |
| 0.5 ms / 5 ms | 0.5 ms | -325 / -339 / -321 dB | 13.4 dB → -7.4 dBFS | -17.1 dB | 0.008 % |
| 12 ms / 24 ms | 12.0 ms | -325 / -291 / -315 dB | 9.0 dB → -3.1 dBFS | -140.9 dB | 0.002 % |
| no limiter, device hard clip | 0 | — | THD -12.6 dB | +1.3 dB | — |
| **+6 dB cap, no limiter (shipped)** | 0 | bit-exact | peak -0.02 dBFS, THD -163 dB | -142.6 dB (peak +0.19 dBFS) | 0 |

Bass-boost IMD: 60 Hz at 0.5 + 3 kHz at 0.05 through band 0 at +12 dB; sideband power at 3 kHz ± 60/120 Hz re the
3 kHz tone. Reference chain CPU 0.17 % of a core.

**Decision: no limiter; the combined boost is capped at +6 dB** (`EQHeadroom.default`). AUPeakLimiter is bit-exact
until it engages, but where it actually works — overloads from EQ boost — it is not transparent: short attacks
modulate the music (IMD -17/-27 dB), the long attack needs 12 ms of lookahead (pause would reach the speaker 12 ms
later than one IO buffer + the 5 ms ramp), and every setting takes 9–13 dB off a 6 dB overload. The rule is
encoded in the report (`transparentBelowFullScale && lowLatency && cleanWhenEngaged`); none passed.

**The cap** lowers only the applied preamp (`globalGain`) so that preamp + the EQ curve's peak (the analytic model,
20 Hz–20 kHz) ≤ +6 dB; the curve's shape is kept and nothing changes when there is headroom. Measured: band 4 at +12
→ 6.00 dB; preamp +6 → 6.00; the worst case (12/14/16 kHz at +12, preamp +12, curve peak about +30 dB) → sweep peak
5.999 dB. Residual risk: content that already peaks near 0 dBFS can still exceed full scale by up to 6 dB with a
boost (the bass-boost test peaked at +0.19 dBFS); users lower the preamp as in Winamp.

### Presets and `.eqf`

`EQPresets.builtIn` are MacAmp's 17 (Winamp's defaults minus Flat) plus `EQPresets.flat`; `EQF.decode/encode` read
and write Winamp EQ library files (one or many entries; Windows-1252 names, 256 bytes max + NUL; trailing partial
entries ignored; out-of-range bytes read as -12 dB). One slider mapping is shared by presets and the codec: value 33
(byte 31) is exactly 0 dB, 64 is +12 dB (31 steps), 1 is -12 dB (32 steps). MacAmp used two mappings that disagree
by up to 0.19 dB; Webamp's puts flat at +0.19 dB. The 17 presets round-trip through `.eqf` exactly; arbitrary gains
round-trip within half a step (≤ 0.194 dB), and a second trip is exact.

## Balance

`AudioEngine.setBalance(_:)` (and the existing `RenderBridge.setBalance`) set per-channel gains in the C bridge,
interpolated across one callback. Law: Winamp-like — unity on both channels at the centre (no pan-law dip), the
opposite channel attenuated linearly; full left leaves the right channel at exactly 0. NaN means centre.

## Visualiser data

`VisualiserAnalyser(bridge:)` → `analyse(nowNanos:) -> VisualiserFrame` at whatever rate SkinUI draws (30 Hz).

- **Window.** The newest 1024 mono samples, ending `bridge.latencyFrames` before the ring's write position:
  `latencySeconds` is the output presentation latency + one IO buffer (11.92 ms = 572 frames on the built-in
  speakers), which `AudioEngine.refreshLatency()` re-queries on start, after every recovery and after an idle resume.
  A ring that hasn't advanced for 150 ms counts as silence, so bars fall when the engine is stopped; frames between
  two callbacks (large IO buffers) re-read the same window.
- **Spectrum.** Hann window, `vDSP_DFT_zrop` (1024 points, MacAmp's pre-allocated pattern), bin powers, then 19
  log-spaced bands from 40 Hz to 16 kHz (ratio 1.371): each bar is the summed power of the bins whose centre lies in
  the band (bands narrower than a bin interpolate at their centre), in dB re a full-scale sine, mapped from -60 dB
  (empty) to -6 dB (full). A -20 dBFS sine reads -20 ± 0.5 dB.
- **Falloff and peaks**, per second (frame-rate independent), from Winamp's defaults as documented by Webamp: bars
  fall 1.41 heights/s (12/16 rows per 30 Hz frame); peaks hold at the bar's maximum and fall from 0.022 heights/s,
  accelerating ×17.4 per second (×1.1 per frame).
- **Scope.** 76 raw samples evenly spaced across the window, clamped to ±1.
- **Output.** `VisualiserFrame` is a value with inline SIMD storage: `bar(_:)`, `peak(_:)` (0…1), `scope(_:)`
  (-1…1), and `barHeight(_:rows:)`, `peakHeight(_:rows:)`, `scopeRow(_:rows:)` in SkinKit's `VisualizerFrame` units
  (bars 0…16, scope rows 0…15, 0 = top).
- **Zero allocation after init**, verified: a test counts malloc calls through libmalloc's `malloc_logger` hook on
  the test thread: 0 in 1000 analyses (ring and sample paths), in debug and release. That needed `while` loops and
  vDSP in the hot path: at -Onone each iteration of a `for … in` range loop allocates an iterator box (measured).
- **Limit.** A 1024-sample window at 48 kHz has 46.9 Hz bins, so the lowest bars (40–55, 55–75, 75–103 Hz) can't
  separate tones (a 60 Hz tone lights the first two about equally). Tests check bar placement from 250 Hz up.
- The analyser shows the pre-EQ, post-balance signal (DESIGN §5.4: "v1 shows the pre-EQ signal").

**Ring change.** The C ring now publishes a claim (`ring_claimed`, then a release fence) before a callback
overwrites slots, and the reader validates against the claim after its acquire fence: a proper seqlock pairing.
Before, validation used the published position plus a 4096-frame guard, which is safe for one callback in progress
but relies on timing for later ones. API and limits are unchanged (count + lag ≤ 4096). The ring tests (MacAmp's
ideas, restated for a newest-window ring): integrity, empty and invalid reads, overwrite keeps the newest, wrap,
many small writes then one read, mono = (L + R)/2, a paced 48 kHz writer with a 30 Hz reader, and a concurrent
writer/reader stress run over 15.4 M frames with a counter signal: 0 torn reads.

## Device changes

Two changes to `AudioEngine`'s recovery, both from E2's follow-ups (`docs/spikes/E2.md`):

1. **Moves bind before the first start of a fresh engine.** Rebinding `kAudioOutputUnitProperty_CurrentDevice` on the
   running engine's output unit made the HAL post a configuration change ~100 ms after the restart on a device's
   first use, stopping the engine again (first move 465–498 ms). A move now builds a fresh AVAudioEngine, binds the
   device, then attaches, connects and starts (the source and EQ nodes move over). Result: no self-inflicted
   notification in 200 switches (five runs), first move 192–245 ms. The rebuild costs about 8 ms; RSS stayed flat (92 → 82 MB
   across 40 switches). As a safety net, a configuration change within 1.5 s of our own engine start gets a 10 ms
   quiet window instead of 150 ms, and a trigger that arrives during a recovery schedules a re-check instead of
   being dropped. (That short window alone, the first variant tried, brought the first move to 375.6 ms.)
2. **Nothing pauses until a restart is needed.** Triggers no longer host-pause at once; after the quiet window the
   recovery decides. If the output unit already followed the default (the return to the built-in output), audio
   just keeps playing; if the engine must restart, it host-pauses (waiting for the 5 ms ramp while audio flows), pauses
   mpv, moves or restarts, and resumes with the 50 ms fade. A default-output change leaves audio playing on the old
   device during the 150 ms window.

| devswitch --cycles 20 (40 switches) | ≤ 500 ms | p50 | p95 | max | first move | → aggregate median | → built-in median | silence per switch (median, → agg / → built-in) | self-inflicted notifications |
|---|---|---|---|---|---|---|---|---|---|
| E2 run 1 / 2 (M0) | 40 / 40 | 169.4 / 170.1 | 223 | 494.8 / 493.1 | 494.8 / 493.1 | 205–230 | 155–170 | — | 1 |
| M3 baseline (pre-change code, new metric) | 40 | 169.9 | 226.9 | 464.9 | 464.9 | 220.1 | 160.2 | 219 / 160 | 1 |
| short self-inflicted window only | 40 | 105.5 | 241.7 | 375.6 | 375.6 | ~229 | ~104 | — | 1 |
| **final, run 1** | **40** | 125.6 | 241.8 | **249.8** | 228.0 | 237.2 | 106.3 | **77 / 76** | **0** |
| **final, run 2** | **40** | 124.1 | 245.7 | **249.1** | 242.0 | 237.3 | 104.9 | **77 / 77** | **0** |

The metric is stricter than E2's: audio counts only once the output unit reports the target device (a watcher thread
polls `kAudioOutputUnitProperty_CurrentDevice` every 2 ms) and after the last gap of ≥ 25 ms without audible
callbacks, so a later dropout or audio still playing on the old device can't flatter it. Moves to the aggregate got
about 17 ms slower (the ramp wait and the rebuild), but silence per switch fell from 219 / 160 ms to about 77 ms.

## Idle stop

`scheduleIdleStop(after: 30)` stops the AVAudioEngine unless `cancelIdleStop()`, another schedule, `start()`,
`stop()` or `resumeFromIdleStop()` comes first; `idleStopNow()` does it immediately (for callers that time the 30 s
themselves); `isIdleStopped`; `resumeFromIdleStop() throws -> Bool` restarts it, rebinding the default output if it
changed meanwhile and reconnecting for the current device's format. A device change while idle-stopped only rebinds
the device. Tests run on an offline engine (no device): stop after the delay, restart, cancel, supersede, explicit
stop is not idle, `idleStopNow` idempotent.

**Integration (PlaybackController):** pause = `hostPauseAndWaitForRamp()` → `mpv.setPause(true)` →
`scheduleIdleStop()` (or `idleStopNow()` after your own 30 s); resume = `try resumeFromIdleStop()` →
`mpv.setPause(false)` → `hostResume(fadeSeconds:)`. Prefer these to `stop()`/`start()` for suspension: a plain
`stop()` looks like a dead engine to the device recovery, which restarts it, and a plain `start()` after a device
change doesn't reconnect for the new format. Prefer `AudioEngine.setBalance` (so `balance` reads back) over
`audio.bridge.setBalance`.

## Commands

```
swift run --scratch-path .build-audio sudamp-dev eq-selftest --json            # gates + persist + shelf-ab + limiter
.build-audio/release/sudamp-dev eq-selftest --mode gates|persist|shelf-ab|limiter --json
.build-audio/release/sudamp-dev bench-transport .build/fixtures/ramp60.wav --seconds 30 --json
.build-audio/release/sudamp-dev stress-lifecycle 100 --json
run.sh --cycles 20 --json   # trap '<sudamp-dev> devswitch --restore' EXIT INT TERM HUP; <sudamp-dev> devswitch "$@"
make verify-binary && build/sudamp.app/Contents/MacOS/sudamp --selftest --json
swift test --scratch-path .build-audio -Xswiftc -plugin-path -Xswiftc <CLT>/usr/lib/swift/host/plugins/testing --filter AudioTests
```

## Open

- Bluetooth (E2 manual checklist) is still unrun; IO buffer and latency there are larger, which the visualiser lag
  and the stall window account for but nobody has measured.
- The +6 dB cap bounds gain, not output level: hot masters with a boost can still clip at the device by up to 6 dB.
  A signal-aware auto-preamp (or a custom lookahead limiter in C) is a v1.x candidate.
- The idle stop is an API: the 30 s pause/idle policy itself belongs to PlaybackController (playback agent).
