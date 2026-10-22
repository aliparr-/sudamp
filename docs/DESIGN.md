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
- **UI.** AppKit only (SwiftUI's `@State` doesn't compile without Xcode [measured]): Main + shade, EQ + presets and the Playlist as station list, pixel-exact, in an original skin, "sudamp Dark".
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

**Goals:** the north star; `.wsz` skins drawn pixel-exact; no single source failure silences a genre; ≤ 3% CPU playing, ≤ 0.5% paused; a clean licence and trademark trail; every behaviour verifiable from a terminal. **Non-goals:** video, downloads, accounts, cookies; the Mac App Store (guidelines 2.5.2, 2.4.5, 5.2.3 [source]); Milkdrop, local files, telemetry; Intel, Windows, Linux. **After v1.0:** post-EQ visualiser, loudness normalisation, Mixcloud widget mode (if chosen, §13), EQ/Playlist shade and resize, double-size, cursors, 1.5x scale, an in-app skin museum, hotkeys, sleep timer, Preferences, and our own libmpv build.

## 3. User experience

**Decision.** Only one action matters, picking a genre, so it is impossible to miss and always produces sound within about 2 s.

**First launch.** Main and Playlist open docked in sudamp Dark (2x on Retina), the marquee reads `*** CLICK HERE TO PICK A GENRE ***`, nothing plays, and yt-dlp (about 54 MB) downloads (from M7, after the feed fetch, §7.2). The genre menu opens once on its own; hovering a genre for 300 ms pre-resolves its next pick. A pick before the engine is ready plays one of the genre's ≥ 2 radio stations while the marquee shows `PREPARING STREAM ENGINE 63%`. No terms-of-service modal: About and the README state that sudamp is unofficial and credit creators.

**Returning launch.** Layout, skin, scale, EQ and volume are restored and the last genre auto-resumes with a 1.5 s fade: a VOD from its saved position if quit under 6 h ago with over 5 min left, live at the live edge, else the next bag item. yt-dlp is warmed with `--version` (1.6 s cold, 0.15 s warm [measured]).

**The dropdown.** One NSMenu builder, opened from a marquee click (under 3 px of movement), the options button, right-click `Genre ▸`, the menu-bar **Genre** menu (⌘1–⌘9, ⌘0 Surprise Me), the status item and the Dock menu. It ticks the current genre, disables one with no playable streams (with the reason), and ends with ★ Favourites, Surprise Me and Recently Played ▸. The Playlist lists the genre's streams tagged `YT`/`SC`/`MC`/`FM`; the marquee shows `[DEEP HOUSE] CREATOR - TITLE` or the ICY title.

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

**`AudioRender`** (ObjC) builds a 48 kHz stereo Float32 source node whose callback outputs silence under host-pause, else reads with `delay = presentationLatency + frames/48000`, applies balance and ramps (5 ms; 1.5 s launch fade), stamps TTFA and writes a mono mix into an 8192-frame SPSC ring (MacAmp's algorithm, C11 atomics). It never enters Swift: a MainActor-created Swift render closure trapped on the IO thread [measured], and the macOS 27 SDK marks Swift unsupported on realtime threads [source].

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

**Per file:** `loadfile <url> replace -1 <node map>` with yt-dlp's `http-header-fields` and `user-agent`, `force-media-title`, `start=<s>` on resume, `http-proxy` when a system proxy is set (§6.2), and `stream-lavf-o`: progressive formats get `request_size` from `downloader_options.http_chunk_size`, like mpv's ytdl_hook [source] (10 MiB for YouTube, whose unbounded ranges are throttled to 32 KiB/s [measured]; ~5 MB for Mixcloud's `http` fallback [source]), an equal `short_seek_size` (E1 checks pass-through) and `reconnect=1,reconnect_streamed=1,reconnect_delay_max=10`; radio gets `reconnect_streamed=1`.

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

**Visualiser.** A 30 Hz `NSView.displayLink` reads the newest 1024 samples; a Hann-windowed vDSP FFT (MacAmp's zero-allocation pipeline) feeds 19 log-spaced bars (40 Hz–16 kHz) and a 76-sample scope, drawn at 1x in viscolor colours stepped per row. The ring leads playback by one IO buffer plus `presentationLatency` (~12 ms on built-in speakers, derived from the 512-frame buffer and 1.25 ms measured latency), so the reader lags the write index by that sum, re-queried on device change [unverified on Bluetooth, E2]. `installTap` (100 ms buffers [measured]) is not used. v1 shows the pre-EQ signal.

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

Breakers half-open with one probe; a success resets that stream's health. Without cookies or PO tokens, a blocked user hears the other sources.

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

**Radio URLs** must be http(s) on a real hostname (no IP literal, localhost, `.local`, `.internal` or single label), without userinfo, on port 80, 443 or 1024–65535, and a direct stream; before playback the host is resolved and loopback, private and link-local addresses are rejected. mpv gets `config=no`, `load-scripts=no`, `load-unsafe-playlists=no` and array commands only; a test proves a crafted `file://` m3u8 fails.

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
- One uniform scale (1, 2 or 3; 2 on Retina), toggled with ⌘D; docking maths stays in skin pixels. EQ sliders use Bitamp's geometry, Webamp's 51 px travel. Every hotspot gets an NSAccessibility element.

### 8.2 Loading `.wsz`
- **Reader:** Bitamp's `ZipArchive`, with caps checked **before allocating**: 32 MB per entry (declared, compressed and while inflating), 96 MB total, 512 entries, stored or deflate only. Uncapped, a 1 MB zip bomb pushed the reader to 2.16 GB [measured].
- **Matching** by whitelisted lower-cased basename; images take the last match, `pledit.txt` the first, as in Webamp [source]. ImageIO decoded 2,029 real BMPs with 0 failures [measured]; sprites are clipped to their sheet. **Fallbacks:** missing sheet → sudamp Dark; `nums_ex` over `numbers`; balance → volume; Webamp's EQ-maximise rule. **Magenta:** follow Webamp, no colour key; M7 re-checks MacAmp issue #84 [unverified].
- **Tables:** sprites come from `scripts/gen-sprites.py` (grown from `spikes/skins-tools/extract_sprites.py`) run on Webamp's `skinSprites.ts` @ `7734cd3` (212 sprites, MIT header kept), not wamp's table (14 wrong rects); layout draw rects come from Bitamp's `Layout.swift`, cross-checked against Webamp's CSS and the Strider spec. **Parsers:** wamp's ini, viscolor and pledit; macamp's tolerant region parser with Webamp's semantics; all run against Webamp's fixtures.
- **region.txt:** our own rasteriser fills alpha without anti-aliasing (even-odd, right and bottom edges exclusive: the X11/Wine lattice-point rule, `spikes/s1-region`), then calls `invalidateShadow()`. Click-through is WindowServer behaviour [measured, S1]: while `ignoresMouseEvents` is never assigned, clicks on alpha-0 pixels go to the window below (any app) and the hit shape follows content changes; assigning `false` turns that off, so `SkinWindow` never touches the property and has no `hitTest` override. The shadow follows the alpha shape [measured]. S1's manual real-click check is pending; if it fails, region.txt ships in v1.1.

### 8.3 Text, default skin, trademark
- **Text:** Webamp's FONT_LOOKUP (`<>{}` → `[]`), diacritics stripped; the marquee (31 characters, 5 px every 220 ms, `"  ***  "`) is Webamp's pure model with its tests. Characters the skin font lacks (CJK, emoji) get a Core Text overlay in text.bmp's colours at ≥ 2 device pixels per skin pixel, else `applyingTransform(.toLatin)`. Playlist rows use Core Text in pledit.txt colours.
- **sudamp Dark:** `skingen` ports Bitamp's Canvas, original PixelFont, DefaultSkin and WszWriter (MIT), with fixed ZIP timestamps; the output is committed and `skin-check` enforces byte identity. Near-black panels, graphite bevels, the icon's teal accent, title `SUDAMP`; no Nullsoft pixels, no Bitamp branding. AndAmp Dark and Light (CC BY 4.0, Mattix) ship with credits and double as fixtures.
- **Trademark:** no Winamp name, llama, bolt or `WINAMP` title in branding; only nominative use ("plays classic Winamp skins"). Third-party skins arrive only by user action ("Get more skins…" opens skins.webamp.org).

## 9. Project structure and build

**Decision: SwiftPM plus a Makefile on the Command Line Tools; no Homebrew packages.** MPVKit 1.0.0 comes via SwiftPM (verified on this CLT-only machine: 271 MB of artifacts, static libmpv [measured]); yt-dlp via EngineStore's own upstream download; QuickJS-NG pinned by version and SHA-256 from its official release, copied into `Contents/Helpers/qjs` by `scripts/fetch-qjs.sh`. `jq` is `/usr/bin/jq`.

```
Package.swift  Makefile  LICENSE  THIRD_PARTY_NOTICES.md  PROVENANCE.md  .github/workflows/ci.yml
Sources/<one dir per §4 target>/   Tests/<library>Tests/   ThirdParty/mpv-0.41.0/   Fixtures/   catalog/{feed.json, genres/}
Support/{Info.plist.in, dev.entitlements, AppIcon.iconset, warnings-allowlist.txt}   spikes/ (preserved spike code)
docs/{DESIGN.md, PLAN.md, research/, spikes/ (reports), feedback/, measurements.md}   scripts/ (named where used)
```

**Package.** swift-tools 6.2, `.macOS(.v15)`, arm64; MPVKit `exact: "1.0.0"` (1.1.0-n9.0.2 is a pre-release [source]); Sparkle 2.10 from M8. Swift can't share a target with C/ObjC [measured]: AudioRender is one clang target (`.m` plus `.c`), and SudampAO a separate C target isolating the LGPL code. No asset catalogs, SwiftUI or XCTest.

**Info.plist** (`Support/Info.plist.in`, via `plutil`): `LSMinimumSystemVersion` 15.0; `CFBundleURLTypes` for `sudamp`; an exported `.wsz` UTI plus `CFBundleDocumentTypes`, needed for drag-to-Dock and `open -a`.

**Warnings policy.** The macOS 27 SDK deprecates AVAudioEngine `connect` and related calls for macOS 27-only replacements [measured: MacAmp's build]. sudamp keeps the old calls, confined to `Audio/GraphCompat.swift`, and `scripts/check-warnings.sh` fails `make build` on any warning not in `Support/warnings-allowlist.txt`.

**Make targets.** `test` runs `swift test --parallel -Xswiftc -plugin-path -Xswiftc $(PLUGINS)` with `PLUGINS := $(shell dirname $$(xcrun -f swift))/../lib/swift/host/plugins/testing`, which works on CLT and Xcode toolchains (without it TestingMacros goes missing [measured]), then `count-escapes.sh`. `app` assembles `build/sudamp.app` (`MacOS/sudamp`, `Helpers/qjs`, resource bundles, `feed.json`, an `.icns` from `scripts/make-icon.sh`, a `plutil` Info.plist), ad-hoc signed without the hardened runtime; `app-hardened` adds `--options runtime`, plus `dev.entitlements` with `disable-library-validation` once Sparkle is embedded, since an ad-hoc hardened binary can't load an ad-hoc framework [measured]. Also `verify-binary` (§5.3 plus `codesign --verify --strict`), `skin-check`, `golden` (~100 complete museum skins; tracked, not a gate), `smoke`, `soak`, `release`.

**Tests** (Swift Testing, library targets) cover the pure core (hostile URLs, seeded bags, fake-Clock breakers, SessionMachine, argv goldens, Feeds tamper/rollback/expiry), SkinKit (fixtures, zip bombs, fuzzing), `MPVTests` pulling `sudamp_ao_read` with a ramp WAV, and offline-rendered EQ (§5.4). Render goldens compare the SHA-256 of the decoded RGBA8 buffer (`render` and `--snapshot` also write `.rgba` and `.sha256`), since PNG bytes vary across macOS versions. **Agent hooks:** `sudamp-dev`; `--automation`, `--snapshot`, `--plain`, `--selftest`; `sudamp://`; debug `state.json`; `log show` (subsystem `app.sudamp`); `metrics.jsonl`; `SUDAMP_HOME`/`--profile`, `SUDAMP_FAULT`, `SUDAMP_LIVE=1`, and (debug builds only) `SUDAMP_CLOCK_OFFSET=<s>`, `SUDAMP_PROXY=<url>`, `SUDAMP_FEED_URL=<url>`.

**CI and the macOS 15 floor.** Local checks all run on macOS 27. `.github/workflows/ci.yml` runs `make build test` on a GitHub `macos-15` runner (caching MPVKit's 271 MB of artifacts); it is committed in M0 and runs once the repo has a GitHub remote, which it lacks today. Whether that runner's toolchain accepts swift-tools 6.2 is [unverified, M0]. Before 1.0 a scripted smoke test runs in a macOS 15 VM (M9).

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
| AndAmp | Dark/Light `.wsz` | CC BY 4.0 (Mattix) |

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

No ATS exceptions: URLSession is HTTPS-only; mpv's sockets sit outside ATS. Sparkle 2.10 needs `-Wl,-rpath,@loader_path/../Frameworks` and preserved symlinks [source]; the app offers to move itself to /Applications. **Channels:** GitHub Releases and a Homebrew cask (`auto_updates true`) in our own tap. homebrew/cask disables casks failing Gatekeeper (since 2026-09-01) and `--no-quarantine` is deprecated [source], so public installs need a Developer ID. THIRD_PARTY_NOTICES is generated in M8 from MPVKit 1.0.0's binary targets plus QuickJS-NG, Sparkle, the ledger and AndAmp; yt-dlp is credited in About, not redistributed.

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
| Skin art | Code-generated sudamp Dark |
| First launch | Wait for a pick; menu auto-opens once |
| Auto-resume | On |
| Domain | Register before M8, which bakes in the bundle ID and feed URL; M7 can use `<user>.github.io` |
| Genres | 12, proposed by the agent and approved by the owner |
| EU legal opinion | Before promotion |
| Foundation | Build fresh on libmpv |
