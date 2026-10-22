# Research (2026-10-22)

The evidence behind `docs/DESIGN.md`. Four deep-research reports were each fact-checked by an independent agent. **Where a correction in a report's "Verification checks" section conflicts with the original claim, the correction wins.** Three hands-on evaluations followed.

| File | Topic |
|---|---|
| `engine.md`, `findings-engine.md` | Playback engine: IINA, libmpv/MPVKit, EQ, visualiser data, AVPlayer/VLCKit alternatives |
| `sources.md`, `findings-sources.md` | yt-dlp on YouTube/SoundCloud/Mixcloud, JS runtimes, latency, internet radio, ToS facts |
| `skins.md`, `findings-skins.md` | Classic `.wsz` format, sprite tables, Webamp, native rendering, genre-picker placement |
| `shell.md`, `findings-shell.md` | AppKit shell, SwiftPM build on Command Line Tools, notarization, licensing, catalog, picker |
| `eval-enginespike.md` | Hands-on engine test: pull AO vs FIFO vs lavfi EQ (code in `spikes/engine-pull-ao/`) |
| `eval-macamp.md` | Whether hfyeomans/MacAmp could be the fork base (verdict: borrow pieces, don't fork) |
| `eval-priorart.md` | Bitamp, andrehickmann/macamp, wamp, MacWamp, Webamp: which components to port |

Each `findings-*.md` lists every claim with its source URL and a confidence level. Versions and behaviour are as of the date above. yt-dlp and YouTube facts in particular go stale quickly.
