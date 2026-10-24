# sudamp: design (v1)

*The Sudden Amp · 2026-10-22 · Status: Proposed — awaiting owner review of §13 decisions*

**Evidence.** **[measured]**: run on the dev machine (macOS 27.0.1, M5 Pro, Command Line Tools only). **[source]**: upstream code or docs. **[unverified]**: owned by a named spike or milestone in `docs/PLAN.md`. Research, findings with source URLs and evaluation reports are in `docs/research/` (fact-check corrections win); spike code is in `spikes/`.

## 1. Summary

- **The loop.** Open sudamp, pick a genre from a native dropdown on the skinned marquee, and a random curated stream plays; Next plays another in that genre.
- **Build fresh and borrow; fork nothing.** sudamp uses IINA's foundation (libmpv), not its code (a GPLv3 video app with no library product), and ports about a dozen MIT modules (§9).
- **Engine.** MPVKit 1.0.0 (static mpv v0.41.0) decodes; a link-time **pull audio output (AO)** feeds sudamp's own AVAudioEngine graph (§5).
- **v1 sources:** YouTube (mixes and 24/7 `/live`), SoundCloud, Mixcloud (the owner named it; included by default pending the owner's §13 decision on its terms-of-service risk, §6.5) and internet radio, which every genre includes for instant start and outages.
- **yt-dlp** runs isolated, downloaded from upstream, never bundled or hosted (§6).
- **One signed feed, local first.** `feed.json` carries the catalog and engine settings. Until M7 only the bundled copy is used; M7 adds the signed remote copy, as the owner asked: "stored server side so we can update it dynamically, but to start let's keep it local".
- **UI.** AppKit only (SwiftUI's `@State` doesn't compile without Xcode [measured]), in two skin classes the user switches between (§8.4): the default **modern** skin, native Liquid Glass in light or dark with a choice of tints; and the **classic** skins, Main + shade, EQ + presets and the Playlist as station list, pixel-exact, in an original skin, "sudamp Dark", or any `.wsz`.
- **North star first:** headless at M1, then an unskinned NSPopUpButton window at M2, before any skin work reaches the app (SkinKit, M4, may be built in parallel from M0).
- **Shipping:** SwiftPM and a Makefile on the Command Line Tools, no Homebrew packages; GPL-3.0-or-later (AO LGPL-2.1+); Developer ID, notarized DMG, Sparkle, a Homebrew cask in our own tap; macOS 15+, Apple silicon.

## 2. Goals, non-goals and v1 scope

**Decision.** v1 is a radio-style player over four source types with the core Winamp window set; everything else waits.

Time to first audio (TTFA), from menu action to first non-silent sample, is stamped in C and logged to `metrics.jsonl`.

| Case | Target | Basis |
|---|---|---|
| Radio (HTTP or HTTPS) | ≤ 1.5 s | HTTPS radio audible in 0.9 s [measured] |
| Next or already-resolved pick | ≤ 1.0 s p50 | 24 ms loadfile [measured] |
| Cold SoundCloud / Mixcloud pick | ≤ 2.0 s / ≤ 2.5 s | 0.6 s / 1.0 s resolve [measured] + stream open [unverified, R1] |
| Cold YouTube pick (VOD or `/live`) | ≤ 3.0 s p50, ≤ 3.5 s p90 | 1.15–1.4 s VOD resolve [measured] + stream open [unverified, R1] |
| First launch, engine downloading | ≤ 2 s via radio | Radio needs no yt-dlp |

**Goals:** the north star; `.wsz` skins drawn pixel-exact; no single source failure silences a genre; ≤ 3% CPU playing, ≤ 0.5% paused; a clean licence and trademark trail; every behaviour verifiable from a terminal. **Non-goals:** video, downloads, accounts, cookies; the Mac App Store (guidelines 2.5.2, 2.4.5, 5.2.3 [source]); Milkdrop, local files, telemetry; Intel, Windows, Linux. **After v1.0:** post-EQ visualiser, loudness normalisation, Mixcloud widget mode (if chosen, §13), EQ/Playlist shade and resize, double-size, cursors, an in-app skin museum, hotkeys, sleep timer, Preferences, and our own libmpv build.

## 3. User experience

**Decision.** Only one action matters, picking a genre, so it is impossible to miss and always produces sound within about 2 s.

**First launch.** The modern player opens (§8.4) with a glowing *Pick a Genre* button (classic skins: Main and Playlist docked in sudamp Dark, 2x on Retina, the marquee reading `*** CLICK HERE TO PICK A GENRE ***`), nothing plays, and yt-dlp (about 54 MB) downloads (from M7, after the feed fetch, §7.2). The genre menu opens once on its own; hovering a genre for 300 ms pre-resolves its next pick. A pick before the engine is ready plays one of the genre's ≥ 2 radio stations while the marquee shows `PREPARING STREAM ENGINE 63%`. No terms-of-service modal: About and the README state that sudamp is unofficial and credit creators.

**Returning launch.** Layout, skin, scale, EQ and volume are restored and the last genre auto-resumes with a 1.5 s fade: a VOD from its saved position if quit under 6 h ago with over 5 min left, live at the live edge, else the next bag item. yt-dlp is warmed with `--version` (1.6 s cold, 0.15 s warm [measured]).

**The dropdown.** One NSMenu builder, opened from a marquee click (under 3 px of movement; the modern skin's genre button), the options button, right-click `Genre ▸`, the menu-bar **Genre** menu (⌘1–⌘9, ⌘0 Surprise Me), the status item and the Dock menu. It ticks the current genre, disables one with no playable streams (with the reason), and ends with ★ Favourites, Surprise Me and Recently Played ▸. The Playlist lists the genre's streams tagged `YT`/`SC`/`MC`/`FM`; the marquee shows `[DEEP HOUSE] CREATOR - TITLE` or the ICY title.

**Controls.** `X`/`C`/`V` play, pause, stop (pause is silent within one IO buffer behind a 5 ms ramp; live or radio paused over 30 s rejoins the live edge); `B` next random stream; `Z` history; seek on VOD only; ⌘F favourite; ⌘⌫ never play again (undoable); Eject or ⌘L opens a stream URL; Copy Link credits the creator, with `&t=` (YouTube) or `#t=` (SoundCloud). Settings are Options and View menu toggles. Closing Main quits via the quit path (§4).

| Situation | Behaviour |
|---|---|
| A stream fails or is restricted (e.g. Mixcloud's replay limit) | Advance within ~1 s; `SKIPPING - UNAVAILABLE` |
| 5 failures in a row | Stop; `CAN'T REACH STREAMS - CLICK TO RETRY` |
| YouTube bot-check or 429 | YouTube pauses 6–24 h; other sources carry on |
| Engine missing or updating; github.com unreachable | Radio only; `UPDATING STREAM ENGINE` / `ENGINE DOWNLOAD FAILED - RADIO ONLY` (retries) |
| Offline | `OFFLINE`; resumes by itself |
| Audio engine guard fails (§5.3) | Refuses to play; `AUDIO ENGINE ERROR` |

## 4. Architecture

**Decision.** One process; logic in pure, testable modules; only Shell wires them together.

| Target | Isolation | Responsibility |
|---|---|---|
| `sudamp` | executable | `main.swift` |
| `Shell` | MainActor default | composition root, menus, status item, URL scheme, Now Playing, PlaybackController, persistence, instance forwarding, quit, `--plain`, `--automation`, debug `state.json` |
| `SkinUI` | MainActor | SkinWindow, layers, controls, docking |
| `SkinKit` | **pure** | ZIP, sheets, tables, parsers, region rasteriser, marquee, visualiser renderer, composer, hit-test, skin generator |
| `Catalog`, `Picker` | **pure** | feed model, canonicaliser, validator; bags, health, breakers, `SessionMachine` |
| `Resolver` | actor + pure | argv, error classifier, ResolverService, EngineStore, token bucket, cache, proxy |
| `Feeds` | nonisolated | bundled snapshot (M1); fetch, Ed25519, anti-rollback, expiry (M7) |
| `MPV` | `@unchecked Sendable` | handle, event thread, async commands, guards |
| `Audio` | nonisolated | AVAudioEngine graph, EQ, volume, device changes, vDSP analysis |
| `AudioRender` | ObjC/C | render block, SPSC ring |
| `SudampAO` | C, **LGPL-2.1+** | pull AO + vendored mpv v0.41.0 headers |
| `Core` | **pure** | IDs, Clock (debug `SUDAMP_CLOCK_OFFSET`), RNG, paths (`SUDAMP_HOME`), logging, metrics, `Subprocess`, instance lock, signals |
| Tools | executables | `sudamp-dev` (headless player, benchmarks, render, faults, soak), `skingen`, `catalog-tool` (M7) |

**Rules.** Pure modules never import AppKit or AVFoundation; LGPL code stays in one target; tests use library targets only. `scripts/count-escapes.sh` (run by `make test`, and by CI once a GitHub remote exists) fails on any `@unchecked`, `nonisolated(unsafe)` or `@preconcurrency` without a `// SAFETY:` comment on the same or previous line.

**Single instance:** an exclusive `flock` on `<profile>/instance.lock`; a second launch forwards its URL or arguments over `<profile>/instance.sock` and exits 0, and `sudamp-dev play` refuses a locked profile.

**Quit path.** ⌘Q, `sudamp://quit` and SIGTERM (a Core `DispatchSource` on the main queue whose handler, installed by Shell, calls `NSApp.terminate`) run one sequence: a 5 ms fade, the engine shutdown order (§5.2), a flush of the debounced `session.json` and `library.json`, exit 0. Automation needs no Apple Events (and no TCC prompt).

**Threads:** main; mpv's; `sudamp.mpv.events`, blocking in `mpv_wait_event(h,-1)`; the CoreAudio IO thread (C/ObjC only, no allocation); one yt-dlp child per resolve.

```
 genre menu ─► PlaybackController ─► SessionMachine ─► Picker.next(genre) ─► StreamRef
                                                                               │
   radio ◄──────────────── (no resolve) ◄──────────────────────────────────────┤
     │                                     ResolverService ─posix_spawn─► yt-dlp (+qjs, tier 2)
     │                                          │  ResolvedStream {url, headers, availableAt, expire}
     ▼                                          ▼
 MPVClient.loadfile(url, {headers, stream-lavf-o})   ── libmpv: network → cache/demux → decode → 48 kHz f32
                                                                               │  AO queue
 CoreAudio IO thread: render block (C/ObjC) ─► sudamp_ao_read ─► ao_read_data ◄┘
     pause · ramps · balance · TTFA ─► SPSC ring ─► vDSP analyser (30 Hz) ─► SkinUI visualiser
 AVAudioSourceNode ─► AVAudioUnitEQ ─► mainMixer (volume) ─► output device
```

`SessionMachine` is a pure reducer, `(State, Event) → (State, [Effect])`. States: idle, tuning, buffering, playing, paused, offline, failed. Events include user actions, mpv events, resolve results and `networkLost`/`networkRestored` (NWPathMonitor). Effects: resolve, load, pause, prefetch, persist, nowPlaying, flash. PlaybackController only executes effects, so playback logic is testable without mpv.

## 5. Playback engine

### 5.1 Decision
| Option | Evidence | Verdict |
|---|---|---|
| **libmpv → link-time pull AO → AVAudioEngine** | 0 short reads, pause ≤ 9.6 ms, seek 9.6–10.8 ms, loadfile ≈ 24 ms, property reads 7 µs, 1.1% CPU [measured] | **Chosen** |
| `ao=pcm` into a FIFO | Blocks the mpv core ~1.3 s at a time; pause 1.93 s; 1.7–2.7 s stale audio on seek; deadlocks [measured] | Rejected |
| `ao=coreaudio` + lavfi EQ | Gains lost unless the `af` string is kept in sync [measured]; hotplug crash; no visualiser filters [source] | E1 NO-GO contingency only |
| Own FFmpeg engine / AVPlayer | ~8–9k lines of mpv to rewrite / no WebM-Opus, no EQ on HLS | Rejected |

MPVKit's static libmpv exports only `_audio_out_pcm` from `audio_out_ao_pcm.c.o`, while `ao_read_data` and `mp_time_ns` are global, so a sudamp-defined driver wins at link time; the internal ABI it uses is unchanged from v0.41.0 to master [measured], and upstream has no PCM API (PR #16769 closed unmerged [source]). mpv's CoreAudio output and its hotplug crash are never used; the visualiser reads real PCM with no permission prompt. M0's E1 ports the spike in `spikes/engine-pull-ao/`.

### 5.2 Pull AO, render bridge, mpv options
**`SudampAO`** (~80 lines) defines `const struct ao_driver audio_out_pcm`, description `"sudamp pull AO"`, `device_buffer` 1024.
- `init` sets `ao->format=AF_FORMAT_FLOATP`, `ao->samplerate=48000` and stereo itself, so mpv inserts the resampler; `sudamp_ao_read` returns silence and bumps an error counter unless `ao->samplerate==48000` and format and channels match. The `audio-samplerate` option is only belt and braces.
- `sudamp_ao_read(float *L, float *R, int frames, int64_t delay_ns)` calls `ao_read_data(ao, planes, frames, mp_time_ns()+delay_ns, NULL, true, true)` under a trylock (ao_coreaudio's pattern). `sudamp_ao_init_count()` and `sudamp_ao_error_count()` feed the guards.
- `scripts/vendor-mpv-headers.sh` (`clang -MM`) vendors the v0.41.0 headers into `ThirdParty/mpv-0.41.0/`. The spike's hand-written 4-line `config.h` gives way to `scripts/gen-mpv-config.sh`, which takes every `HAVE_*` macro those headers test from MPVKit 1.0.0's meson arguments (BuildScripts at tag 1.0.0) or mpv's macOS default, failing on any it can't resolve: a wrong value silently shifts struct layouts.

**`AudioRender`** (ObjC) builds a 48 kHz stereo Float32 source node whose callback outputs silence under host-pause, else reads with `delay = presentationLatency + frames/48000`, applies balance and ramps (5 ms; 1.5 s launch fade), stamps TTFA and writes a mono mix into a 65,536-frame SPSC ring (MacAmp's algorithm, C11 atomics). It never enters Swift: a MainActor-created Swift render closure trapped on the IO thread [measured], and the macOS 27 SDK marks Swift unsupported on realtime threads [source].

**mpv options.** `setlocale(LC_NUMERIC,"C")` and `signal(SIGPIPE, SIG_IGN)` come first [source]. Then, before `mpv_initialize`:
```
config=no  load-scripts=no  ytdl=no  osc=no
load-<builtin>=no for every built-in script option in 0.41.0     # names verified in E1
vid=no  vo=null  audio-display=no
ao=pcm                                  # resolves to the linked "sudamp pull AO"
audio-samplerate=48000  audio-channels=stereo  audio-buffer=0.2  gapless-audio=weak
volume=100  volume-max=100  af=
cache=yes  demuxer-max-bytes=64MiB  demuxer-readahead-secs=30  network-timeout=15
idle=yes  load-unsafe-playlists=no  input-media-keys=no  media-controls=no  msg-level=all=warn
```

**Per file:** `loadfile <url> replace -1 <node map>` with yt-dlp's `http-header-fields` and `user-agent`, `force-media-title`, `start=<s>` on resume, `http-proxy` when a system proxy is set (§6.2), and `stream-lavf-o`: progressive formats get `request_size` from `downloader_options.http_chunk_size`, like mpv's ytdl_hook [source] (10 MiB for YouTube, whose unbounded ranges are throttled to 32 KiB/s [measured]; ~5 MB for Mixcloud's `http` fallback [source]), an equal `short_seek_size` (E1 checks pass-through) and `reconnect=1,reconnect_streamed=1,reconnect_delay_max=10`; radio gets `reconnect_streamed=1`. Every load also bounds the demuxer cache: `cache-secs=30` (with `cache=yes`, mpv's `cache-secs` would otherwise override `demuxer-readahead-secs`), `demuxer-donate-buffer=no`, `demuxer-max-back-bytes=8MiB` for VOD and `1MiB` for radio and live (PLAN M6 soak: without them RSS reached 457 MB in 24 min [measured]).

**Observed:** `pause`, `time-pos`, `duration`, `seekable`, `media-title`, `metadata` (`icy-title`), `audio-params` (display), `audio-out-params` (guard), `audio-bitrate`, `paused-for-cache`, `idle-active`. Live means `seekable=no` or the feed's `kind` (live ICY reports a growing `duration` [measured]).

**Lifecycle.** The UI uses only `mpv_command_node_async`; seek and skip are just the command, since `ao_reset` clears mpv's queue. Pause sets the host flag first, so silence is instant; mpv is paused only once the 5 ms ramp has rendered (`AudioEngine.hostPauseAndWaitForRamp`), because pausing mpv at once emptied the AO read and cut the ramp in every E1 sample [measured]. The audio engine stops after 30 s paused or idle, and live or radio paused over 30 s is reloaded at the live edge on resume (re-resolving an expired YouTube `/live` URL). Shutdown: stop the engine → set the stopping flag → `mpv_wakeup` → join the event thread → `mpv_terminate_destroy`; the wrong order crashed the spike [measured], so `sudamp-dev stress-lifecycle 100` guards it.

### 5.3 Guards
**Decision.** The override is proven at build time and checked at runtime; a failure stops playback, and there is no second engine.

| When | Check |
|---|---|
| Build (`make verify-binary`) | `strings` finds `sudamp pull AO`, not `RAW PCM/WAVE file writer`; the linker map (`.build/sudamp-link.map`) attributes `_audio_out_pcm` to the SudampAO object (`sudamp_ao.o`, or `SudampAO.o` under the swiftbuild backend) and loads no `audio_out_ao_pcm.c.o` member; `otool -L` lists only `/System/Library` and `/usr/lib` entries, plus `@rpath/Sparkle.framework/Versions/B/Sparkle` once M8 embeds it |
| Startup | `mpv-version` starts with `mpv v0.41.` |
| First file | init count > 0; `audio-out-params` reports format=floatp, samplerate=48000, channels=stereo (`audio-params` is the decoder output) |
| Every read | the AO error counter stays 0 |

A failed runtime guard is logged, shows `AUDIO ENGINE ERROR` and blocks playback; debug builds assert. `ao=coreaudio` with the verified lavfi EQ (`volume@pre`, `equalizer@b0…b9`, `af` string kept in sync) is only E1's NO-GO contingency, never shipped: a second engine and EQ, without the #18383 hotplug fix or a visualiser.

### 5.4 EQ, volume, balance, visualiser
**EQ.** `AVAudioUnitEQ`: 10 parametric bands (60/170/310/600 Hz, 1/3/6/12/14/16 kHz), 1 octave, ±12 dB; preamp `globalGain`; off `bypass`. Gains never pass through mpv, so they survive seeks and new files. Only flat, band 4 (+12.00 dB) and preamp (+6.00 dB) are measured [measured]. M3's `eq-selftest` checks all ten bands on an AVAudioEngine in `enableManualRenderingMode(.offline, …)`, which needs no audio device and is deterministic (AVAudioSourceNode renders offline [measured, M3]). M3 also A/B-tests shelves for bands 0 and 9 and evaluated AUPeakLimiter: bit-exact below full scale but not transparent when engaged (IMD −17 to −27 dB at ≤ 2 ms attack, 12 ms latency otherwise), so the combined boost is capped at +6 dB by lowering the applied preamp; shelves read only 6 dB at their labelled frequency, so all ten bands stay parametric [measured, M3; docs/spikes/M3-audio.md]. Presets: MacAmp's 17 and `.eqf` codec.

**Volume** is `mainMixer.outputVolume = (v/100)²`; **balance and fades** are per-channel gains in the C bridge, since `AVAudioMixing.pan` is unmeasured as a stereo balance.

**Visualiser.** A 30 Hz `NSView.displayLink` reads the newest 1024 samples; a Hann-windowed vDSP FFT (MacAmp's zero-allocation pipeline) feeds 19 log-spaced bars (40 Hz–16 kHz) and a 76-sample scope, drawn at 1x in viscolor colours stepped per row (the classic skins; the modern skin's scenes pull the same analyser at 30 Hz too, §8.4). The ring leads playback by one IO buffer plus `presentationLatency` (~12 ms on built-in speakers, derived from the 512-frame buffer and 1.25 ms measured latency), so the reader lags the write index by that sum, re-queried on device change. The ring holds 65,536 mono frames (1.37 s) less a 4096-frame guard for a callback in progress, so the 1024-frame window can end up to 1.26 s back: Bluetooth's 100–300 ms fits. It was 8192 frames, which left room for only 64 ms of latency: beyond that every read failed and the visualiser heard silence (every modern scene stood flat on headphones). A latency beyond even that (AirPlay) is clamped, so the bars run a little early rather than going silent. `installTap` (100 ms buffers [measured]) is not used. v1 shows the pre-EQ signal.

### 5.5 Devices, Now Playing, Swift 6
**Device changes.** On `AVAudioEngineConfigurationChange`, debounced 150 ms (MacAmp's observer and tests): host-pause and pause mpv, `stop()` + `reset()` (avoids error −10868), reconnect, `start()`, unpause with a 50 ms fade; after 3 failed starts, rebuild the engine. On macOS 27 AVAudioEngine neither follows nor reports a change of the default output to a same-format device [measured, E2], so the app enables `AudioEngine.setFollowsDefaultOutput(true)`: a HAL listener on `kAudioHardwarePropertyDefaultOutputDevice` that binds `kAudioOutputUnitProperty_CurrentDevice` through the same debounced recovery (40/40 switches audible within 500 ms, p50 170 ms). Bluetooth is still [unverified, E2 manual]; M3: a move binds the device before the first start of a fresh engine (no self-inflicted notification; first move 192–245 ms), and nothing pauses unless the engine must restart (return to the built-in output about 105 ms) [measured, docs/spikes/E2.md].

**Now Playing.** sudamp owns `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`: `playbackState` on every transition, `IsLiveStream` for live, `ExcludeFromSuggestions = true`; next is a random pick, previous is history, seek is VOD-only.

**Swift 6.** UI targets use `.defaultIsolation(MainActor.self)`. Every system or C callback that can fire off the main thread (mpv events, NWPathMonitor, DispatchSource, `AVAudioEngineConfigurationChange`, CoreAudio property listeners) is registered only from the nonisolated MPV, Audio, Resolver or Core modules, as an explicitly `@Sendable` closure or nonisolated func, hopping to the main actor via `Task { @MainActor in … }`.

## 6. Stream resolution

### 6.1 Delivering yt-dlp
**Decision.** The engine is the official onedir `yt-dlp_macos.zip` (53.9 MB, ~107 Mach-O files, 0.15 s warm start [measured]), downloaded by the app and never bundled: bundling makes sudamp the distributor, the conduct OLG Hamburg addressed [source]; bundled copies go stale (a 7-month-old build returned URLs that 403'd [measured]); and onedir breaks Apple's flat-code rule [source].

**Install** (in the background, while radio plays):
1. **Choose** from the active feed (§7.2), always honouring `block` and upstream's `_update_spec` lock lines: `pin` (its SHA-256 copied from upstream's `SHA2-256SUMS`, by hand before M7 and by `catalog-tool build` from M7) if present and not blocked, else the newest non-blocked release with its `SHA2-256SUMS`.
2. **Download** into a `.partial` file after checking for ~180 MB free (54 MB zip + 123 MB unpacked [measured]); interruptions resume with an HTTP Range request, and an unreachable github.com is reported and retried with backoff.
3. **Verify** the SHA-256 and unpack with `ditto -x -k --noqtn`. A non-sandboxed app's writes aren't quarantined unless `LSFileQuarantineEnabled` is set [source]; assert no quarantine xattr.
4. **Record** `tree.json` (path, mode, SHA-256 of every file), which every launch re-hashes in the background before the first resolve, because `_internal/` is user-writable; a mismatch reinstalls.
5. **Test** with `--version`. An update must also pass the **canary**: resolve the feed's canary YouTube and SoundCloud items plus a YouTube range GET, with its own `--cache-dir`.
6. **Switch** atomically via `current.json`, keeping the previous build.

**Updates** run right after a `pin` first install, at launch after 24 h, daily, and after engine-class failures (at most every 2 h). The candidate is always the newest non-blocked upstream release behind the canary, so `pin` never holds an update back and an old bundled snapshot can't freeze the engine. Never `-U`. **Nightly escalation** (when stable fails the canary with engine errors, try the newest nightly behind the canary) ships in M6 if spike R1 finds the artifact, else v1.x. **Plan B:** `EngineFlavor`, an argv-prefix abstraction, can switch to a bundled signed Python running the 3 MB zipapp (costed by spike R2).

### 6.2 Invocation
argv only, scrubbed environment:
```
env: HOME=<AS>/sudamp/engine-home  XDG_CONFIG_HOME=<AS>/sudamp/engine-home/.config
     XDG_CACHE_HOME=<Caches>/sudamp/xdg  TMPDIR=<Caches>/sudamp/tmp
     PATH=/usr/bin:/bin  LANG=en_US.UTF-8  YTDLP_NO_PLUGINS=1
<AS>/sudamp/engines/yt-dlp/<ver>/yt-dlp_macos
  --ignore-config --no-plugin-dirs --no-update --no-js-runtimes
  [--js-runtimes quickjs:<app>/Contents/Helpers/qjs]        # tier 2 only
  [--proxy http://<host>:<port>]                            # only when a system proxy is set
  --cache-dir <Caches>/sudamp/yt-dlp  --no-playlist --socket-timeout 10 -J
  <per-source flags>  -- <canonical URL>
```

| Source | Default flags (the feed can override them) |
|---|---|
| YouTube VOD | `--extractor-args youtube:player_client=visionos -f "bestaudio[ext=webm][format_id!*=drc]/bestaudio[format_id!*=drc]/bestaudio"` |
| YouTube `/live` | the JS ladder's `--extractor-args youtube:player_client=<tier clients>` plus `-f "bestaudio[protocol^=m3u8]/worst[protocol^=m3u8]"` (audio-only itags 233/234 seen [measured]) |
| SoundCloud | `--extractor-args soundcloud:formats=hls_aac -f "hls_aac_160k/hls_aac_96k/bestaudio"` |
| Mixcloud | `-f "hls-192/http/bestaudio"` (HLS AAC, progressive m4a and DASH opus are offered [source]; older uploads have no `hls-192` and fall back to 64 kbit progressive `http`, which also opened faster than HLS in R1 [measured]) |
| Radio | no yt-dlp; mpv opens the curated direct URL |

**Process rules.** The private HOME neutralises the user's yt-dlp config and plugins; warnings are logged as early signs of breakage; never `--exec`, `--netrc-cmd`, external downloaders, cookies or `player_skip` (it triggered a bot-check at once [measured]). Each resolve gets its own process group, killed on cancel or at 10 s (12 s on tier 2).

**System proxy.** Unlike URLSession, yt-dlp (in its scrubbed environment) and FFmpeg don't read macOS proxy settings, so before each resolve and load Resolver reads `CFNetworkCopySystemProxySettings` and passes an HTTP(S) proxy to yt-dlp (`--proxy`) and mpv (`http-proxy`); PAC-only and SOCKS-only setups are logged as unsupported. FFmpeg tunnels HTTPS through `http-proxy` with CONNECT, including redirect targets [measured, M1].

**JS ladder** (order and clients from the feed). Tier 1: `visionos`, no JS runtime, 1.15–1.4 s, itags 251/140 (JS-less is deprecated upstream [source]). Tier 2, the guaranteed fallback: `visionos,tv_samsung` with bundled QuickJS-NG ≥ 0.12 (MIT, 1.3 MB, no JIT), 3.4–3.6 s [measured]. `--no-js-runtimes` comes first because yt-dlp ranks Deno 1000 > QuickJS 850 > WebKit 500 [source]. Two tier-1 failures while tier 2 works start picks at tier 2 for 24 h. The WebKit JSI plugin (a private EJS hook) and JavaScriptCore wait for yt-dlp PR #15041. No Deno: 81.5 MB, not notarized, development ending around Oct 2027 [source].

### 6.3 Results, waits, expiry, prefetch
- **Fields used:** format `url`, `http_headers`, `protocol`, `available_at`, `abr`, `downloader_options`; `duration`, `live_status`, `title`, `uploader`, `webpage_url`, `thumbnail`; the URL's `expire`/`expires`. Media hosts must be HTTPS with an allowlisted suffix [measured, R1]: YouTube `googlevideo.com` (`rr*---sn-*` for VOD, `manifest.googlevideo.com` for `/live`), SoundCloud `media-streaming.soundcloud.cloud`, Mixcloud `mixcloud.stream` (`dl.` progressive, `aod.` HLS/DASH).
- **`available_at`** appears only on YouTube progressive formats (absent on `/live` HLS, SoundCloud and Mixcloud [measured, R1]); absent means no wait. With ads it can be 15–30 s or more ahead [source]. Never load before it; if a cold pick must wait over 3 s, keep the resolution and play the next pick.
- **Cache** until `expire − 15 min`: YouTube ~6 h, IP-bound, dropped when the network path changes; SoundCloud ~2.8 h [measured, R1] (the cache follows each URL's `expires`); Mixcloud HLS showed no expiry [measured], so it is kept 1 h. Long mixes re-resolve 10 min before expiry; a mid-stream error or 403 reloads at `start=<time-pos>`, then moves on.
- **Prefetch** the next pick ~10 s after first audio (depth 1); progressive YouTube URLs also get a 64 KB range GET after `available_at` (a 403 is an engine error), HLS and radio aren't probed.
- **Rate.** YouTube resolves draw from one token bucket shared by user picks, prefetch, hover, canary and retries: burst 3, refill 1 per 30 s, so at most 123 in any hour (burst 3 + 120 refills) and 120/h sustained, about 40% of the ~300 videos/hour guest limit [source]. Hover pre-resolve spends a token only when ≥ 2 remain; with no token left, YouTube items are deferred for that pick.
- **Concurrency.** One resolve at a time; a user pick kills a prefetch or hover resolve. Only the canary runs alongside, with its own `--cache-dir`, so no two processes share one [source]. A slow cold pick shows `TUNING…`; v1 has no parallel race.

### 6.4 Failure classes
| Class | Signals | Action |
|---|---|---|
| unavailable | private, removed, geo-blocked, preview, DRM; Mixcloud `restrictedReason` `tracklist`/`repeat_play`, exclusive or login-required [source] | Skip 24 h, then 7 d; 3 failures over ≥ 7 d hide it until the next feed revision |
| transient | timeout, 5xx, DNS | Retry once, then back off 1 h → 24 h; 3 failures across ≥ 2 streams in 10 min open the source breaker, 15 min doubling to 2 h |
| engine | 403 on a fresh URL, format unavailable, n-challenge failure | Step up the JS ladder; after 2 in a row, an update check and a 15 min → 1 h breaker |
| botCheck / 429 | "Sign in to confirm you're not a bot", LOGIN_REQUIRED, 429 | YouTube degraded 6 h → 12 h → 24 h (blocks have lasted 2–3 weeks [source]) |

Breakers half-open with one probe; a success resets that stream's health. Without cookies or PO tokens, a blocked user hears the other sources. Radio has no source breaker (each station is its own host). "Retry once" applies to quick transient failures (< 3 s); a timeout moves on at once.

### 6.5 Terms of service and legal
**Decision.** sudamp is an unofficial client that reduces exposure without claiming to remove it.
- **YouTube:** its ToS and API policies forbid automated access, circumvention, separating audio from video, and background play; being free doesn't change that [source].
- **SoundCloud:** its API terms forbid genre-radio aggregation [source].
- **Mixcloud:** its ToS (5.1.5, 5.1.8) forbid circumventing restrictions and scraping, Mixcloud says streams are only for its visible widget, and yt-dlp's extractor decrypts `streamInfo` with a key that literally reads `IFYOUWANTTHEARTISTSTOGETPAIDDONOTDOWNLOADFROMMIXCLOUD` [source]. Free listeners have replay limits, so `repeat_play` errors will occur.
- **OLG Hamburg** (5 U 54/23, 2024) held YouTube's cipher to be an effective technical protection measure, and hosting youtube-dl unlawful [source].

The practical risks are breakage, bot-checks and distribution pressure, not suits against users. sudamp streams only, credits creators, uses no cookies, leaves extraction to upstream yt-dlp, keeps a takedown path and gets an EU legal opinion before promotion.

## 7. Catalog and feed

### 7.1 Feed document and canonicaliser
**Decision.** One versioned document, `feed.json`, carries the catalog and the engine settings.
```json
{ "schema": 1, "revision": 7, "generatedAt": "2026-10-22T10:00:00Z", "expiresAt": "2027-04-22T00:00:00Z",
  "catalog": { "genres": [ { "id": "deep-house", "name": "Deep House", "order": 10 } ],
    "streams": [ { "id": "mc:someuser/some-mix", "source": "mixcloud", "ref": "someuser/some-mix", "kind": "mix",
      "title": "…", "creator": "…", "genres": ["deep-house"], "durationSec": 3720, "weight": 1.0 } ] },
  "engine": { "minAppVersion": "0.1.0", "pin": { "version": "…", "sha256": "…" }, "block": [],
    "sources": { "youtube": true, "soundcloud": true, "mixcloud": true }, "nightlyEscalation": true,
    "fastStartRank": ["radio", "soundcloud", "mixcloud", "youtube"], "clients": ["visionos", "visionos,tv_samsung"],
    "formats": { "mixcloud": "hls-192/http/bestaudio" }, "extractorArgs": {}, "mediaHosts": ["…"], "canary": ["yt:…", "sc:…"] } }
```
Sources are `youtube`, `youtube-live` (`@handle` or `UC…` ID), `soundcloud`, `mixcloud` and `radio` (stream URL plus `homepage`); switching a source off in `engine.sources` (its kill switch) makes its items ineligible. Decoding is lenient per item; an unknown major `schema` rejects the document. URLs are always rebuilt from the ref, and pasted URLs follow the same rules:

| Source | Accepted ref | Rebuilt URL |
|---|---|---|
| `youtube` | `^[A-Za-z0-9_-]{11}$` | `https://www.youtube.com/watch?v=<id>` |
| `youtube-live` | `^@[A-Za-z0-9._-]{3,30}$` | `https://www.youtube.com/<@handle>/live` |
| `youtube-live` | `^UC[A-Za-z0-9_-]{22}$` | `https://www.youtube.com/channel/<id>/live` |
| `soundcloud` | `^[a-z0-9_-]+/[a-z0-9_-]+$` | `https://soundcloud.com/<user>/<slug>` |
| `mixcloud` | `^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$` | `https://www.mixcloud.com/<user>/<slug>/` |

**Radio URLs** must be http(s) on a real hostname (no IP literal, localhost, `.local`, `.internal` or single label), without userinfo, on port 80, 443 or 1024–65535, and a direct stream; before playback the host is resolved and loopback, private and link-local addresses are rejected. mpv gets `config=no`, `load-scripts=no`, `load-unsafe-playlists=no` and array commands only; a test proves a crafted `file://` m3u8 fails. FFmpeg follows no redirect (`max_redirects=0`); sudamp follows them itself, re-checking every hop (M6).

### 7.2 Feeds: bundled first, remote in M7
**Decision.** The app uses only its bundled snapshot until M7, which publishes and fetches the same document, signed.
- **Bundled (from M1).** `Contents/Resources/feed.json`, built from `catalog/`, is sealed by the app's code signature; bundled documents never expire and have no anti-rollback. Its `pin` and `block` apply from M1, even to the first engine install.
- **Remote (M7).** The same document on GitHub Pages (behind the owner's domain once chosen; ETag/304 verified [measured]) with `feed.json.sig`, a raw Ed25519 detached signature checked with CryptoKit against **two** embedded keys for rotation. `catalog-tool sign` uses CryptoKit, as LibreSSL lacks Ed25519 [measured]; from M7 the bundled copy is signed too, so one verification path serves both.
- **Fetching (M7):** at launch with a 5 s budget, in parallel with radio playback and *before* EngineStore chooses a version, then every 12 h; `If-None-Match`, User-Agent `sudamp/<ver>`, no identifiers; a failed or rejected fetch retries after 1 h. Until the owner generates the production key (before M8), release builds stay bundled-only.
- **Active document.** A fetched document must verify, have `revision` ≥ the cached one (anti-rollback) and `minAppVersion` ≤ the app's. `expiresAt` applies to fetched documents only: an expired one falls back to the cached copy, then the bundled one. The highest valid revision wins.
- **Strict validation before anything reaches argv**, bundled or fetched; a failing value keeps its previous value. Client lists match `^[a-z_]+(,[a-z_]+)*$`; format strings use only `[A-Za-z0-9_\-\[\]\^\*!=/,.<>?:+]` and must not start with `-`; extractor args match `^[a-z]+:[a-z_]+=[a-z0-9_,]+$`; media hosts are lower-case DNS suffixes; `pin`/`block` versions match `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$` and `sha256` is 64 lower-case hex.
- Expiry never freezes the engine, because `pin` only chooses the first install (§6.1).
- **Tests** point debug builds at a scratch feed via `SUDAMP_FEED_URL`, signed with a committed test key (`Fixtures/keys/test-ed25519.*`) that only debug builds trust.

### 7.3 Picker, state, curation
```
build(g):    key(s) = U(0,1)^(1/weight(s)); order = eligible sorted by key desc   // Efraimidis–Spirakis
             k = min(3, n/3); move the last k played out of order[0..<k]
next(g):     walk from cursor; ineligible items are deferred, not consumed; on exhaustion rebuild once
eligible(s): ¬banned ∧ now ≥ nextEligibleAt ∧ source enabled ∧ breaker[source] ≠ open ∧ (radio ∨ engineReady)
             ∧ (source ≠ youtube ∨ tokens ≥ 1 ∨ resolution cached)
fast-start:  first pick after a genre change or launch: among the next 3 eligible, prefer a ready
             item (radio or an unexpired cached resolution), then by fastStartRank
```
New IDs from a feed change go at random positions after the cursor; ★ Favourites has its own bag; Surprise Me weights genres by eligible count. **State** (atomic, debounced 2 s): `library.json` (favourites, bans, 200 history entries), `session.json` (bags, health, breakers, last session), and the local `~/Library/Logs/sudamp/metrics.jsonl` (`{ts, event, source, streamId, ms, class, tier}`) that acceptance tests read.

**Curation.** From M7, `catalog/feed.json` is generated by `catalog-tool build` from `catalog/genres/*.json`, `release.json`, `engine.json` and `pins.json` (docs/catalog.md); unit tests check that it is current and lint-clean. M7's `catalog-tool` adds `build` (from `catalog/genres/*.json`), `lint`, `sign`, `probe` (resolve plus range GET from a residential IP) and `discover` (radio-browser, `scsearch`, and Mixcloud's no-auth public API `api.mixcloud.com/discover/<tag>/popular/` [measured]). SoundCloud items need policy ALLOW or MONETIZE, |duration − full_duration| < 2 s and a clear AAC transcoding; Mixcloud items must not be exclusive and must `probe` without a `restrictedReason`. Each 1.0 genre needs ≥ 15 streams, ≥ 2 radio stations from ≥ 2 broadcasters and ≥ 2 source types; genres grow 3 (M1) → 6 (beta, M7) → 12 (1.0, M9). SomaFM's API is closed to third parties [source], so ask before listing its stations.

## 8. Skins and UI

### 8.1 Renderer
**Decision.** A pure compositor draws each window at 1x; AppKit only displays and moves the result.
- `WindowComposer.render(window, state, skin)` returns an RGBA8 frame at 1x (Main/EQ 275×116, Playlist 275×232 fixed, shade 275×14); it and `Layout.hitTest` are pure. The frame becomes `layer.contents` with `.nearest` filtering; visualiser and marquee are sublayers, so the base recomposes only on state changes.
- `SkinWindow` is borderless and clear, overrides `canBecomeKey/Main` (both false otherwise [measured]) and drags itself. Docking is Bitamp's `Docking.swift` with Webamp's **15 px** snap and `snapUtils` tests; dragging Main moves its cluster as child windows. MacAmp's screen guard and clamp (`addObserver(forName:)` for macOS 15) recover windows after sleep or display changes.
- One uniform scale (1x, 1.2x, 1.5x, 2x, 2.5x or 3x; 2x on Retina), picked in the View menu, with ⌘D toggling 1x and 2x; docking maths stays in skin pixels. 1x, 2x and 3x are pixel-exact; the others round each window to whole points and stretch the 1x frame over it, so some skin pixels are a device pixel wider or taller. EQ sliders use Bitamp's geometry, Webamp's 51 px travel. Every hotspot gets an NSAccessibility element.

### 8.2 Loading `.wsz`
- **Reader:** Bitamp's `ZipArchive`, with caps checked **before allocating**: 32 MB per entry (declared, compressed and while inflating), 96 MB total, 512 entries, stored or deflate only. Uncapped, a 1 MB zip bomb pushed the reader to 2.16 GB [measured].
- **Matching** by whitelisted lower-cased basename; images take the last match, `pledit.txt` the first, as in Webamp [source]. ImageIO decoded 2,029 real BMPs with 0 failures [measured]; sprites are clipped to their sheet. **Fallbacks:** missing sheet → sudamp Dark; `nums_ex` over `numbers`; balance → volume; Webamp's EQ-maximise rule. **Magenta:** follow Webamp, no colour key; M7 re-checks MacAmp issue #84 [unverified].
- **Tables:** sprites come from `scripts/gen-sprites.py` (grown from `spikes/skins-tools/extract_sprites.py`) run on Webamp's `skinSprites.ts` @ `7734cd3` (212 sprites, MIT header kept), not wamp's table (14 wrong rects); layout draw rects come from Bitamp's `Layout.swift`, cross-checked against Webamp's CSS and the Strider spec. **Parsers:** wamp's ini, viscolor and pledit; macamp's tolerant region parser with Webamp's semantics; all run against Webamp's fixtures.
- **region.txt:** our own rasteriser fills alpha without anti-aliasing (even-odd, right and bottom edges exclusive: the X11/Wine lattice-point rule, `spikes/s1-region`), then calls `invalidateShadow()`. Click-through is WindowServer behaviour [measured, S1]: while `ignoresMouseEvents` is never assigned, clicks on alpha-0 pixels go to the window below (any app) and the hit shape follows content changes; assigning `false` turns that off, so `SkinWindow` never touches the property and has no `hitTest` override. The shadow follows the alpha shape [measured]. S1's manual real-click check is pending; if it fails, region.txt ships in v1.1.

### 8.3 Text, default skin, trademark
- **Text:** Webamp's FONT_LOOKUP (`<>{}` → `[]`), diacritics stripped; the marquee (31 characters, 5 px every 220 ms, `"  ***  "`) is Webamp's pure model with its tests. Characters the skin font lacks (CJK, emoji) get a Core Text overlay in text.bmp's colours at ≥ 2 device pixels per skin pixel, else `applyingTransform(.toLatin)`. Playlist rows use Core Text in pledit.txt colours.
- **sudamp Dark:** `skingen` ports Bitamp's Canvas, original PixelFont, DefaultSkin and WszWriter (MIT), with fixed ZIP timestamps; the output is committed and `skin-check` enforces byte identity. Near-black panels, graphite bevels, the icon's teal accent, title `SUDAMP`; no Nullsoft pixels, no Bitamp branding. AndAmp Dark, Light and Spot (CC BY 4.0, Mattix) ship with credits; Dark and Light double as fixtures.
- **Trademark:** no Winamp name, llama, bolt or `WINAMP` title in branding; only nominative use ("plays classic Winamp skins", "Winamp Skin Museum").
- **Bundled museum skins (owner decision, 2026-10-23):** the 100 skins of the `make golden` corpus ship in a Skins ▸ Skin Museum submenu (ids `museum:<md5>`), each credited by its museum file name in the tooltip and About. They carry no licence statement, so this overrides the research recommendation to bundle only licensed skins (`docs/research/skins.md`); some show third-party trademarks or photographs. The public repository holds only their list, `Fixtures/skins/museum.json`; `make app` copies the files into `Contents/Resources/Skins/Museum` with `scripts/fetch-museum-skins.sh` (from the golden cache, downloading and MD5-checking any that are missing; `MUSEUM_SKINS=0` skips them). Other third-party skins arrive only by user action ("Get more skins…" opens skins.webamp.org).

### 8.4 Skin classes and the modern skin
**Decision (owner, 2026-10-23).** Two skin classes. **Classic**: every skin above (sudamp Dark, AndAmp, the museum's, any `.wsz`), drawn pixel-exact by SkinKit and SkinUI. **Modern**, the new default: a native window drawn with AppKit, Core Animation and Liquid Glass, in light, dark or the system's appearance, tinted (graphite, red, orange, yellow, green, mint, teal (default, the icon's), cyan, blue, indigo, purple, pink).
- **Switching.** `Shell/PlayerStyleHost` is the one front end the app delegate, menus and automation hold; it forwards to `ModernPlayerUI` or `SkinnedPlayerUI` and rebuilds the other at run time, cross-fading the windows. Skins ▸ lists the modern skin (with Appearance ▸ and Tint ▸) above the classic ones; *Use Classic Skins / Use Modern Skin* is ⇧⌘M; the modern skin's appearance popover has the same switch. Choosing a classic skin or opening or dropping a `.wsz` shows the classic windows and is remembered; a `.wsz` argument shows them for that launch only; a refused archive leaves the modern window as it was, with the rejection sheet. The classic windows get `--scale` only the first time a launch builds them. settings.json holds `skinClass` (`modern` | `classic`, default `modern`, older files included), `modernAppearance`, `modernTint`, `modernVisualizer` (a scene, `rotate` or `off`; files from before it carry the classic `visualizer` over), `visualizerInterval` (seconds, 5–600), `artworkColors` and `visualizerEffect` (`none`, `vhs` or `kaleidoscope`); `--style modern|classic` and an automation script's top-level `"style"` choose for one launch only. Both front ends share `Shell/PlayerUIBase`: every menu, sheet, Load/Save .eqf… and the menu automation.
- **ModernUI** (main-actor target, no dependencies) mirrors SkinUI: a pure `ModernPlayerState` in (mapped from snapshots by `Shell/ModernDisplay`, unit-tested), `ModernEvent`s out. One borderless, clear window holds up to three glass cards in one `NSGlassEffectContainerView`: the player (generated artwork with the visualiser, genre button, title, creator, source and format badges or a notice, progress or a live bar, transport, volume, panel buttons), the Equalizer (preamp and ten bands over a glowing response curve, presets, reset, on/off) and Stations (an `NSTableView` of the genre's streams). Panels open and close like drawers: a panel's top edge stays a gap under the card above while its height (and the gap after it) follows a critically damped spring for 0.5 s, and the cards below move with it, so no card passes over another; glass blends only where cards touch (container spacing 0). Liquid Glass follows views' real frames, not Core Animation's in-flight values, so frames are stepped per display frame; inside a glass container a glass view's alpha is ignored, so each card's page of controls fades instead [measured]. Each card's two drop shadows (ambient: blur 13, 9 down; contact: blur 2.5, 1 down) are drawn behind the glass, masked to outside every card, and fade out completely inside the window's 40 pt clear margin (cut off at the edge, they showed as a line); their shape uses a 28 pt corner, since Liquid Glass draws its 30 pt corners at about 27.5 pt [measured]. The window's place and open panels are `<profile>/modern-layout.json`. macOS 15 gets a behind-window frosted material with its own rim (`SUDAMP_GLASS=frosted` shows it on any system).
- **Visualiser.** Twenty-eight scenes play in the artwork, listed in four sections. *Meters & Hi-Fi*: Spectrum (bars with falling peak caps), Oscilloscope (with a phosphor afterglow), Retro LEDs, VU Meters (two backlit needle meters, the lows and the highs, as the analyser is mono; spring–mass–damper needles with about 1.3% overshoot, peak lamps, both slammed into the red on the drop), Heartbeat (an ECG sweep drawing a heartbeat on each kick, the beat clock's BPM and a pulsing heart; it flatlines on pause), Turntable (a record from above whose grooves glint with the bands, a label in the artwork's colours, a tonearm creeping in; a scratch on the drop, braking to a stop in silence) and Speaker (a woofer on a spring that swells towards you on the bass and throws dust on the kicks). *Shapes*: Halo (a radial spectrum), Waterfall (a scrolling spectrogram), Tunnel, Spiral (a ride down a glass helter-skelter: a frosted glass tube winds down round an open shaft in a honeycomb-walled hall, and the camera rides just above it looking in and down, the turns below ringing the shaft; light streaks along the tube's strands, the ride surges on the kicks, each kick lights a band round the tube ahead, the camera rumbles with the speed, jolts on each kick and leans with the surges, and the drop rushes the picture in on itself), Loops (each scope sample plotted against one a quarter of the main tone's period earlier: an XY figure from a mono signal), Pendulums (a fifteen-bob pendulum wave that comes back in line every 36 s, each bob pumped by its band, swinging in unison on the drop) and Cells (Conway's rules on a wrapping 23×23 board, a generation a beat, patterns planted where a band stands out from its own level, a ring of gliders on the drop; not called "Life", a board-game trademark). *Places*: Starfield, Synthwave (a striped sun, mountains whose ridge is the spectrum, a neon floor rolling a line a beat), Skyline (windows lighting floor by floor with their band, an aircraft light on the beat, searchlights after the drop), Fireworks, Aurora (curtains of rays over pines, painting its own night sky), Rain (ripples on a pond with lily pads; the treble is the drizzle, a kick a big drop), Campfire (the demoscene fire fed by the bars, sparks on kicks, embers in silence) and Lava (a lava lamp). *Characters & Games*: Pixel DJ (now and then a tiny toast walks across the front of the stage, or crowd-surfs after a drop), Dancing Toast (a pixel-art slice in sneakers on Pixel DJ's 46-pixel grid, with six routines, a breakdown sway and a jump on the drop; it leans by shifting its upper rows rather than rotating, and its popover tile is its own pixel slice, as SF Symbols has no toast), Breakfast Band (the toast singing in front of an egg on drums, a coffee mug on bass and a croissant on keys), Drumming Cat (an original pixel cat on bongos, a paw for the kicks and one for the hats; it curls up asleep in silence), Rally (a two-paddle table-tennis game whose ball crosses the court in exactly a beat, with multiball on the drop; not named after the arcade trademark) and Demoscene (a plasma, copper bars and the now-playing title on a sine scroller, laid out with Core Text so any script works). Seeds vary the looks (coats, mugs, labels, skylines). Or Rotate, every scene for 10, 20 (default), 30 or 60 s each, cross-fading, in an order of its own (`Visualizer.rotation`) so that neighbours differ; it follows the music too: once a scene has shown 4 s, a breakdown hands a lively scene over to the next calm one (Oscilloscope, Turntable, Loops, Pendulums, Starfield, Aurora, Rain, Campfire, Lava), the timer keeps to calm scenes until the breakdown ends, and the drop brings a lively one back. A genre has scenes that suit it, matched on words in its key like the artwork's hues (lo-fi the Campfire and Rain, ambient the Aurora, techno the Tunnel and Cells, trance the Spiral, house Pixel DJ, deep house the Skyline, drum and bass Rally): Rotate opens on one (unless the scene showing suits it already), and turns to the genre's own scenes first for a mood. Or Off. A click on the artwork shows the next scene (rotating, it skips ahead). The appearance popover has a tile per choice (eight to a row), the interval, the background and the effect; View ▸ Visualizer lists the scenes under their sections' headers, then Rotate, Rotate Every ▸, Off, Background ▸ and Effect ▸. An **effect** lies over any scene: VHS (red and blue pulled a pixel apart, every other line darkened over the artwork too, a tracking band rolling down the picture with a little snow, rows wobbling on a kick, and the deck's PLAY or PAUSE sign) or Kaleidoscope (twelve mirrored 30° wedges of the scene, turning with the music, taken from where the scene is brightest, or darkest on light artwork). Both work on the frame's pixels: twelve rotated, clipped image draws cost 0.5 ms a frame at 2x, a fold through a polar table and a sine table about 0.1 ms; VHS adds about 0.15 ms. The **background** (the artwork's colours, and so the visualiser's) is the genre's (default), the window's (a near-black gradient in the tint under dark glass, a pale one under light glass, with the visualiser in the tint's light or deep colour), a cycle that turns through every hue in 90 s of music, or the source's (YouTube red, SoundCloud orange, Mixcloud blue #5000FF, radio amber; the tint's before anything plays). Each palette carries the visualiser's ink, glow, accent and spark colours; the ink's contrast with the gradient is at least 3:1 on the window scheme and never below the genre colours' own 1.5:1 (white on golden yellow), unit-tested. A scene is a plain class (`ModernUI/Visualizer/Scenes`) that draws with Core Graphics into a bitmap each frame (`SceneRenderer`), deterministic for a seed, from `VisualizerInput`: the analyser's bars, peaks and scope plus what `AudioFeatures` picks out of them (bass, mids, treble, level, kicks as a sharp rise in the bass well above its one-second average, a beat clock that locks to the kicks and keeps their tempo through a breakdown, the breakdown itself and its drop) and the now-playing caption. A breakdown is the bass's low points between hits sitting 0.12 below their usual level for over a second (the usual level is learnt in the first two seconds of sound); a gap in the kicks alone won't do, as a breakdown's bassline keeps setting off kicks between the beats. The drop is the first kick on the downbeat after one, at most once in 8 s. `PixelFont` is a shared 3×5 font for scores, readouts and legends. The bitmaps replaced animated shape-layer paths: a `CAShapeLayer`'s in-flight path has a different element structure from the path it was given (30 elements became 33 [measured]), so starting each 1/30 s path animation from the presentation path blended one bar's corners into the next and the bars tore into fragments for a frame, more often the less regular the frame timing. Each scene but Spiral draws in ≤ 0.3 ms at 2x in a release build (`--scene-sheet` prints it; the sixteen added on 2026-10-24 take 0.03–0.18 ms on average, worst frames up to 0.43 ms, and 0.05–0.21 ms with the Cycle colours, where pictures cached for a palette are kept until it has moved 0.02 in a channel), 30 frames a second: drawing is nearly all of a frame's main-thread cost, so 60 (`SUDAMP_VISUALIZER_FPS=60`, for measurements; scenes move by elapsed time, so any rate works) doubled the CPU (Spectrum 2.3% against 1.0%). Spiral alone asks for 60 (`VisualizerScene.framesPerSecond`; the display link takes the rate of the scene showing, the faster of the two through a cross-fade), as its flight judders at 30. The spiral is the same at every turn and the camera keeps its place beside it, so what each pixel sees (where its ray passes each turn of the tube and how close to the tube's middle, from one equation along the ray, and where it meets the hall) is worked out once for a size; each frame only shades it, moving the textures along, on four bands of rows side by side. On a Retina screen it works at 1.5 pixels a point and is smoothed up. The camera's shake is the picture moved, turned and drawn just far enough in to hide its edges (the geometry stays put). The release preview on a 1x display costs 7.9% CPU for Spiral (7.1% before the shake) against 1.9% for Tunnel [measured, 2026-10-24]; frames in the app take three to four times as long as in a tight loop (Tunnel's 0.1 ms is 0.4 ms there). The release preview playing on a 1x display (`--ignore-occlusion`, `top`, first sample dropped) costs 1.3–1.6% CPU for Spectrum, LEDs, Waterfall, Lava, Pixel DJ, Dancing Toast and Rotate, 1.8% for Tunnel and 2.1–2.5% for the Oscilloscope, Starfield, Fireworks and Halo, against 1.1–1.2% for the old bars and 0.2% with the visualiser off [measured, 2026-10-23]. Core Graphics lessons from getting there: filled shapes beat strokes (round caps cost about 3x), a clipped gradient costs about 0.07 ms, one huge path costs more than the same shapes filled in runs of about 20, and a full-area 1:1 image draw is cheap where a scaled one is not.
- **Motion and cost.** The title glides at 30 points a second after a 2.4 s hold, as a render-server keyframe animation (display refresh rate, no main-thread work) instead of the classic 5 px per 220 ms; it truncates under Reduce Motion. Streams have no cover art, so the artwork is generated (above), with blobs of light that drift and swell with the bass; the visualiser draws 30 frames a second. Nothing animates while paused or stopped (the scene settles to a still frame); the display link runs only while the artwork animates and the window can be seen (`--ignore-occlusion` for measurements). Whether it can be seen is WindowServer's occlusion state; when that says hidden, the app in front on an unlocked screen counts as seen, and otherwise the on-screen windows above it are checked (their bounds need no permission), every second and whenever the app comes to the front or leaves it: a nearly clear window can be reported hidden while it shows (the likely reason the visualiser stood still on macOS 26.6; unconfirmed there). Each start and pause is logged with the reason and the output latency, and debug/state.json's `ui.visualizerRunning` and `ui.visualizerDetail` say the same.
- **Tools.** `sudamp --modern-preview [--appearance] [--tint] [--panels] [--state] [--visualizer] [--interval] [--colors] [--effect] [--backdrop] [--capture <png>] [--capture-burst <dir>] [--open-later|--close-later <panel>]` shows the modern window with a fake state (and a stand-in wallpaper, so the glass has something to bend; the visualiser hears synthesised dance music, sixteen bars with a four-bar breakdown, through the real analyser) and can capture it or a run of frames; `--artwork-sheet <png>` captures the genre artworks; `--dump-frames <json>` writes 32 s of that music's analyser frames and `--scene-sheet <png> --visualizer <scene> --frames <json> [--style dark|light|genre:<key>|source:<name>|cycle:<0…1>] [--effect vhs|kaleidoscope]` plays a scene through them offscreen as a contact sheet and prints its cost per frame. Automation's `snapshot` captures the modern window as it shows (own-window capture, no Screen Recording permission); `Fixtures/automation/modern.json` drives its menus, controls, panels, presets and the switch to classic and back.

## 9. Project structure and build

**Decision: SwiftPM plus a Makefile on the Command Line Tools; no Homebrew packages.** MPVKit 1.0.0 comes via SwiftPM (verified on this CLT-only machine: 271 MB of artifacts, static libmpv [measured]); yt-dlp via EngineStore's own upstream download; QuickJS-NG pinned by version and SHA-256 from its official release, copied into `Contents/Helpers/qjs` by `scripts/fetch-qjs.sh`. `jq` is `/usr/bin/jq`.

```
Package.swift  Makefile  LICENSE  THIRD_PARTY_NOTICES.md  PROVENANCE.md  .github/workflows/ci.yml
Sources/<one dir per §4 target>/   Tests/<library>Tests/   ThirdParty/mpv-0.41.0/   Fixtures/   catalog/{feed.json, genres/}
Support/{Info.plist.in, dev.entitlements, AppIcon.iconset, warnings-allowlist.txt}   spikes/ (preserved spike code)
docs/{DESIGN.md, PLAN.md, research/, spikes/ (reports), feedback/, measurements.md}   scripts/ (named where used)
```

**Package.** swift-tools 6.3, `.macOS(.v15)`, arm64; MPVKit `exact: "1.0.0"` (1.1.0-n9.0.2 is a pre-release [source]); Sparkle 2.10 from M8. Swift can't share a target with C/ObjC [measured]: AudioRender is one clang target (`.m` plus `.c`), and SudampAO a separate C target isolating the LGPL code. No asset catalogs, SwiftUI or XCTest.

**Info.plist** (`Support/Info.plist.in`, via `plutil`): `LSMinimumSystemVersion` 15.0; `CFBundleURLTypes` for `sudamp`; an exported `.wsz` UTI plus `CFBundleDocumentTypes`, needed for drag-to-Dock and `open -a`.

**Warnings policy.** The macOS 27 SDK deprecates AVAudioEngine `connect` and related calls for macOS 27-only replacements [measured: MacAmp's build]. sudamp keeps the old calls, confined to `Audio/GraphCompat.swift`, and `scripts/check-warnings.sh` fails `make build` on any warning not in `Support/warnings-allowlist.txt`.

**Make targets.** `build`, `test` and the `swift run` targets first run `toolchain` (below). `test` runs `swift test --parallel -Xswiftc -plugin-path -Xswiftc $(PLUGINS)`, `PLUGINS` being `lib/swift/host/plugins/testing` in the Swift that builds (without it TestingMacros goes missing on the CLT [measured]), then `count-escapes.sh`. `app` assembles `build/sudamp.app` (`MacOS/sudamp`, `Helpers/qjs`, resource bundles, `feed.json`, an `.icns` from `scripts/make-icon.sh`, a `plutil` Info.plist), ad-hoc signed without the hardened runtime; `app-hardened` adds `--options runtime`, plus `dev.entitlements` with `disable-library-validation` once Sparkle is embedded, since an ad-hoc hardened binary can't load an ad-hoc framework [measured]. Also `verify-binary` (§5.3 plus `codesign --verify --strict`), `skin-check`, `golden` (~100 complete museum skins; tracked, not a gate), `smoke`, `soak`, `release`.

**Tests** (Swift Testing, library targets) cover the pure core (hostile URLs, seeded bags, fake-Clock breakers, SessionMachine, argv goldens, Feeds tamper/rollback/expiry), SkinKit (fixtures, zip bombs, fuzzing), `MPVTests` pulling `sudamp_ao_read` with a ramp WAV, and offline-rendered EQ (§5.4). Render goldens compare the SHA-256 of the decoded RGBA8 buffer (`render` and `--snapshot` also write `.rgba` and `.sha256`), since PNG bytes vary across macOS versions. **Agent hooks:** `sudamp-dev`; `--automation`, `--snapshot`, `--plain`, `--selftest`; `sudamp://`; debug `state.json`; `log show` (subsystem `app.sudamp`); `metrics.jsonl`; `SUDAMP_HOME`/`--profile`, `SUDAMP_FAULT`, `SUDAMP_LIVE=1`, and (debug builds only) `SUDAMP_CLOCK_OFFSET=<s>`, `SUDAMP_PROXY=<url>`, `SUDAMP_FEED_URL=<url>`.

**One Swift everywhere.** Each Swift version gives up type-checking a long expression at a different point, so code that one accepts can fail on another: Swift 6.4 here accepted expressions that the owner's Swift 6.3 and CI's 6.2.4 rejected ("unable to type-check this expression in reasonable time"), and CI failed for eight commits [measured]. `.swift-version` pins one version (6.3.3, the owner's 6.3; swiftly reads the same file). `scripts/toolchain.sh` finds that swift.org toolchain in `~/Library/Developer/Toolchains` or `/Library/Developer/Toolchains`, and the Makefile calls it by path (make 3.81 looks up a simple command on its own `PATH`, not one the Makefile exports [measured]), also putting it first on the scripts' `PATH`. The dev machine's default SDK is macOS 27, whose Swift interfaces need Swift 6.4, so the script picks the newest macOS 26 SDK; the CLT ships both [measured]. Without the toolchain, Xcode's or the CLT's Swift of the same minor version stands in, and any other version fails `make toolchain`, saying what to install. A 6.3 build compiles the macOS 26 branch of `Audio/GraphCompat.swift`, as the owner's build does.

**CI and the macOS 15 floor.** Local checks run on macOS 27. `.github/workflows/ci.yml` installs the pinned swift.org toolchain on a GitHub `macos-15` runner, with Xcode 26.3 for the macOS 26 SDK, then runs `make build test`, caching MPVKit's 271 MB of artifacts. Its errors, warnings and failing tests appear as annotations on the run, which can be read without a GitHub login. Before 1.0 a scripted smoke test runs in a macOS 15 VM (M9).

**Borrow ledger.** `PROVENANCE.md` maps each file to its repo@commit and licence; ported files keep their headers.

| Upstream | Taken | Licence |
|---|---|---|
| Webamp @7734cd3 | sprite table, FONT_LOOKUP, fixtures, marquee utils, slider frames, snapUtils tests, FALLBACKS | MIT © 2015 Jordan Eldredge |
| Bitamp | Canvas, Layout, Docking + tests, slider geometry, DefaultSkin/PixelFont/WszWriter, ZipArchive, scripts | MIT © 2026 Ryan Romanosky and Bitamp contributors |
| wamp | ini/viscolor/pledit parsers, EQ graph colours, zip caps | MIT © 2026 Valerii Bakalenko (+ Webamp notice) |
| andrehickmann/macamp | tolerant `parseRegions`, `-snapshot` pattern | MIT © 2026 André Hickmann Kuschnereit |
| hfyeomans/MacAmp @cb0c77f | ring buffer + 16 tests, config observer, rewiring, 17 presets + EQF, visualiser DSP, screen guard/clamp + tests | MIT © 2025–2026 Hank Yeomans (+ Webamp notice) |
| `spikes/engine-pull-ao/` | `sudamp_ao.c`, ramp-WAV generator, transport bench, `iso6` repro, analysis scripts | own (AO: LGPL-2.1+) |
| `spikes/skins-tools/` | `extract_sprites.py` → `gen-sprites.py`, `compare_sprites.py`, `webamp_ref.py` | own; tables keep Webamp's MIT notice |
| AndAmp | Dark/Light/Spot `.wsz` | CC BY 4.0 (Mattix) |
| Winamp Skin Museum | 100 `.wsz`, unmodified (list in `Fixtures/skins/museum.json`; files fetched at `make app`, not committed) | none stated; owner decision §8.3 |

**Never used:** MacAmp's or wamp's bundled skins; wamp's SpriteCatalog; Butterchurn; MacWamp and the 2024 Winamp source (never read); IINA code (reference only).

## 10. Distribution and licensing

**Licence.** GPL-3.0-or-later; `SudampAO` is LGPL-2.1+. Because libmpv, FFmpeg and the other MPVKit libraries are linked statically, each GitHub Release attaches the complete corresponding source: the sudamp tag, the vendored headers and scripts, MPVKit's BuildScripts at tag 1.0.0, and mirrored source archives of every library linked from MPVKit 1.0.0 (mpv v0.41.0 plus MPVKit patches 0001–0003, FFmpeg n8.1.2, and each LGPL/GPL component listed by `check-notices.sh`), fetched and attached by `scripts/mirror-sources.sh`.

**Signing.** Dev builds are ad-hoc (plus the `app-hardened` probe). Releases sign inside-out with `codesign --force --options runtime --timestamp --sign "Developer ID Application: …"`, never `--deep`: `Helpers/qjs`, Sparkle (XPC services dropped; the app isn't sandboxed), `MacOS/sudamp`, the app. No entitlements: no Lua runs, so LuaJIT shouldn't need `allow-jit` (spike L1 confirms). Enrol for a Developer ID before M8, or earlier only for the optional N1 notarization probe in M0.

**Notarizing:** `ditto -c -k --keepParent` → `notarytool submit --wait` → `stapler staple` → an `hdiutil` DMG, notarized and stapled too. **Release gates:** `codesign --verify --strict`; `spctl -a -vv -t exec` on the app (which covers nested code); for `Helpers/qjs`, `codesign --verify --strict` plus `codesign -dvv` showing `Authority=Developer ID Application`, `flags=0x10000(runtime)` and `Timestamp=` (spctl rejects bare executables as "not an app"); `stapler validate`; `verify-binary`.

```
sudamp.app/Contents/{MacOS/sudamp, Helpers/qjs, Frameworks/Sparkle.framework, Resources/{feed.json, Skins/, CREDITS, …}}
~/Library/Application Support/sudamp/{engines/, engine-home/, feed/, Skins/, library.json, session.json, instance.lock, instance.sock, debug/state.json}
~/Library/Caches/sudamp/{yt-dlp/, yt-dlp-canary/, tmp/, xdg/}   ~/Library/Logs/sudamp/{metrics.jsonl, smoke/}
```

**Profiles.** With `SUDAMP_HOME=<P>` or `--profile <P>`, Application Support/sudamp maps to `<P>/` (so `<P>/session.json`, `<P>/instance.lock`, `<P>/instance.sock`, `<P>/debug/state.json`, `<P>/engines/`), Caches/sudamp to `<P>/Caches/` and Logs/sudamp to `<P>/Logs/` (so `<P>/Logs/metrics.jsonl`). The socket stays at the profile root to keep within the 104-byte Unix socket path limit.

No ATS exceptions: URLSession is HTTPS-only; mpv's sockets sit outside ATS. Sparkle 2.10 needs `-Wl,-rpath,@loader_path/../Frameworks` and preserved symlinks [source]; the app offers to move itself to /Applications. **Channels:** GitHub Releases and a Homebrew cask (`auto_updates true`) in our own tap. homebrew/cask disables casks failing Gatekeeper (since 2026-09-01) and `--no-quarantine` is deprecated [source], so public installs need a Developer ID. THIRD_PARTY_NOTICES is generated in M8 from MPVKit 1.0.0's binary targets plus QuickJS-NG, Sparkle, the ledger, AndAmp and the museum skins; yt-dlp is credited in About, not redistributed.

## 11. Risks and mitigations
| # | Risk | Sev. | Mitigation |
|---|---|---|---|
| 1 | YouTube breaks extraction | High | Canary-gated updates, nightly escalation, JS ladder, feed-driven flags, breakers, radio everywhere, nightly smoke |
| 2 | Pull-AO override lost, or ABI drift | High | Exact pin, vendored headers, generated `config.h`, build and runtime guards; later an in-tree `ao_sudamp` |
| 3 | Legal and distribution pressure (Mixcloud most exposed) | High | Never host or bundle yt-dlp; stream only; credit creators; EU opinion; Mixcloud kill switch (§7.1; decision §13) |
| 4 | Mixcloud replay limits vs skip-heavy play | Med | Classed unavailable and skipped; radio and ≥ 2 source types per genre |
| 5 | macOS gates downloaded engine code | Med | `EngineFlavor` plan B (R2); radio unaffected |
| 6 | Device changes, Bluetooth, sleep | Med | Spike E2, debounced rewiring, engine rebuild, C-only render path, soaks |
| 7 | Bot-checks (VPN users); slow cold picks | Med | ≤ 120 YouTube resolves/h sustained, 6–24 h degradation, radio first, pre-resolve |
| 8 | Hostile skins; unreviewed borrowed code | Med | Caps before allocation, generated tables, fixtures, goldens |
| 9 | Curation is the hidden critical path | Med | 3 → 6 → 12 genres, `catalog-tool`, owner approval |
| 10 | macOS 15 floor never run locally | Low | `macos-15` CI, macOS 15 VM smoke test |

## 12. Milestones
Milestones M0 (spikes) to M9 (1.0) are defined in `docs/PLAN.md`.

## 13. Open decisions
| Decision | Default |
|---|---|
| Licence | GPL-3.0-or-later |
| Mixcloud | Include via yt-dlp as requested (default) / visible-widget mode later / drop |
| yt-dlp delivery | Download from upstream |
| Developer ID | Enrol before M8; earlier only for the optional N1 probe |
| GitHub remote | Create one (none exists) for CI, Pages and Releases |
| Platform | macOS 15+, arm64 |
| Skin art | The modern skin by default (§8.4); code-generated sudamp Dark for the classic skins |
| Bundled third-party skins | AndAmp Dark, Light and Spot (CC BY 4.0), plus 100 unlicensed museum skins (owner, 2026-10-23; §8.3) |
| First launch | Wait for a pick; menu auto-opens once |
| Auto-resume | On |
| Domain | Register before M8, which bakes in the bundle ID and feed URL; M7 can use `<user>.github.io` |
| Genres | 12, proposed by the agent and approved by the owner |
| EU legal opinion | Before promotion |
| Foundation | Build fresh on libmpv |
