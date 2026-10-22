# Catalog seed: the starter `catalog/feed.json`

*2026-10-22 · catalog agent · Status: revision 2 done; the six genres are provisional, pending the owner's approval
(PLAN "Owner actions")*

**Result.** `catalog/feed.json` revision 2: 6 genres, 99 streams (43 → 99). Every genre has all four resolver sources
plus radio, at least 3 stations from at least 3 broadcasters, and **at least 15 streams, so every genre meets the 1.0
rule** (`CoverageRule.release`) as well as M1's. It decodes with 0 dropped items and 0 engine issues. The engine section
is byte-for-byte unchanged (pin 2026.10.21); `revision` is 2, `generatedAt` 2026-10-22T14:45:00Z, and genre `order`
is renumbered 10–60 for the menu order Deep House, House, Techno, Drum & Bass, Lo-fi, Ambient. The 43 revision-1 lines
are unchanged.

| Genre | Streams | YouTube VOD | YouTube `/live` | SoundCloud | Mixcloud | Radio (broadcasters) | ≥ 15 (1.0) |
|---|---|---|---|---|---|---|---|
| Deep House (`deep-house`) | 16 (+3) | 4 | 1 | 3 | 5 | 3 (1.FM, Deep Radio, Technolovers.FM) | yes |
| House (`house`, new) | 16 | 4 | 1 | 4 | 3 | 4 (Sunshine Live, RauteMusik.FM, House Nation UK, NTS) | yes |
| Techno (`techno`) | 16 (+2) | 3 | 1 | 3 | 5 | 4 (Sunshine Live, Techno.FM, Technolovers.FM, RauteMusik.FM) | yes |
| Drum & Bass (`drum-and-bass`, new) | 18 | 4 | 1 | 4 | 5 | 4 (Bassdrive, Kool FM, Sunshine Live, DNBRadio) | yes |
| Lo-fi (`lo-fi`) | 16 | 3 | 2 | 4 | 4 | 3 (REYFM, Hunter.FM, Hotmix Radio) | yes |
| Ambient (`ambient`, new) | 17 | 3 | 1 | 4 | 5 | 4 (Ambient Sleeping Pill, NTS, Radio Record, Ambient.FM) | yes |

By the validator's platform count (YouTube VOD and `/live` are one type) every genre has 4 source types.
`Tests/CatalogTests/BundledFeedTests.swift` now expects the six genre IDs and also checks the 1.0 rule.
`Tests/FeedsTests/FeedsTests.swift:31` still expects 3 genres; it is not the catalog agent's file, so the change is a
requested shared change (`== 6`).

## Revision 2: House, Drum & Bass, Ambient; Deep House and Techno to 15+

Same tools and rules as revision 1 (below): the pinned yt-dlp 2026.10.21 installed with
`sudamp-dev engine install --profile /tmp/sudamp-curation2/profile` (sha256 verified against the pin), run with
`--ignore-config --no-plugin-dirs`, a private `--cache-dir`, no cookies, no accounts. Work dir `/tmp/sudamp-curation2`.

**Radio** (radio-browser `de1.api.radio-browser.info`,
`/json/stations/bytag/<tag>?order=votes&reverse=true&hidebroken=true` for `house`, `soulful house`, `chicago house`,
`vocal house`, `house music`, `drum and bass`, `dnb`, `jungle`, `ambient`, `chillout ambient`, plus `byname/NTS`). No
SomaFM station is listed. Same selection rules: HTTPS, direct stream, real host names, and broadcasters on independent
infrastructure. Each URL was fetched **twice** (14:23–14:26 UTC, `nts-4-to-the-floor` at 14:39; again at
14:40–14:41 UTC) with a checker that needs HTTP 200, an `audio/*` content type, a full 32 KB body, at least 4 chained
MPEG-audio or ADTS-AAC frames in it, and only public addresses (`dig A/AAAA`) for the host and every redirect target;
all 12 passed both times [measured]. The 10 revision-1 stations were re-checked once and all passed too.

| ID | URL | Redirects to | Audio |
|---|---|---|---|
| `radio:sunshine-live-house` | `https://stream.sunshine-live.de/house/mp3-192/stream.sunshine-live.de/` | `sunsl.streamabc.net` | MP3 192 k |
| `radio:rautemusik-house` | `https://streams.rautemusik.fm/house/mp3-192/` | `rautemusik.stream3x.radiohost.de` | MP3 192 k, ICY "House" |
| `radio:house-nation-uk` | `https://streaming.radio.co/s06bd9d805/listen` | — | MP3 192 k, ICY "HouseNationUK" |
| `radio:nts-4-to-the-floor` | `https://stream-mixtape-geo.ntslive.net/mixtape5` | `…radiomast.io` | MP3 256 k |
| `radio:bassdrive` | `https://bassdrive.radioca.st/stream` | — | MP3 192 k, ICY "Bassdrive - Worldwide Drum and Bass Radio" |
| `radio:kool-fm` | `https://admin.stream.rinse.fm/proxy/kool/stream` | — | HE-AAC (ADTS, 22.05 kHz core), ICY "Kool FM" |
| `radio:sunshine-live-dnb` | `https://stream.sunshine-live.de/dnb/mp3-192/stream.sunshine-live.de/` | `sunsl.streamabc.net` | MP3 192 k |
| `radio:dnbradio` | `https://azura.drmnbss.org/listen/dnbradio/radio.mp3` | — | MP3 320 k, ICY "DNBRadio - 24-7 Live Dj Mixes…" |
| `radio:ambient-sleeping-pill` | `https://radio.stereoscenic.com/asp-h` | — | MP3 256 k, ICY "Ambient Sleeping Pill" |
| `radio:nts-slow-focus` | `https://stream-mixtape-geo.ntslive.net/mixtape` | `…radiomast.io` | MP3 256 k |
| `radio:record-ambient` | `https://radiorecord.hostingradio.ru/ambient96.aacp` | — | AAC (ADTS, 44.1 kHz), ICY "Record Ambient" |
| `radio:ambient-fm` | `https://ambient.fm/live/` | `phoebe.streamerr.co:4140` | MP3 128 k, ICY "Ambient.FM…" |

The NTS stream names come from NTS's own `www.nts.live/api/v2/mixtapes`: `mixtape` is "Slow Focus" ("ambient, drone
and ragas") and `mixtape5` is "4 To The Floor" ("house and techno from past to present"). Bassdrive's long-standing
URL is HTTP-only (`au.bassdrive.co:8000`); its HTTPS `radioca.st` mirror is used. Rejected: Ibiza Global Radio (HTTPS
port refused), Cryosleep (HTTP only), WeHouseRadio (ICY name "ZUN radio" did not match the listing). All 11 homepages
answered 200 except `dnbradio.com`, which showed a Cloudflare "release maintenance" 503 at check time; its stream
passed both checks.

**Mixcloud** (no-auth API: `discover/<tag>/popular/` for `house`, `drum-and-bass`, `drumandbass`, `dnb`, `ambient`,
`deep-house`, `techno`, and `<user>/cloudcasts/` for Defected, Glitterbox, Toolroom, Hospital Records, LTJ Bukem,
DJ Marky, Mixmaster Morris, low light mixes, NTS, Ninja Tune, Anjunadeep, Adam Beyer, Carl Cox). Official label,
artist, radio and festival accounts only. The public API marks exclusive uploads with `"is_exclusive": true` (seen on
Toolroom Trax mixes, Carl Cox's Cabin Fever, many Hospital mini-mixes and some Mixmaster Morris mixes); **none of the
17 picks carries it**. All 17 were fully extracted with yt-dlp `-J` (formats, no restriction error) and 10 were resolved
through the production path, `sudamp-dev resolve --source mixcloud` [measured]: Defected Radio Show (Monki), Toolroom
Radio EP863, Hospital Podcast #500, LTJ Bukem Dekmantel 2025, DJ Marky Jungle D&B Classics II, Boards of Canada
(NTS), Mixmaster Morris Slow Mountain 1, low light "Favorite Ambient Tracks", Anjunadeep Edition 615, Drumcode DCR841
(690–1692 ms; `hls-192` from `aod.mixcloud.stream`, older uploads `http` from `dl.mixcloud.stream`).

**SoundCloud** (`scsearch15:` flat searches: "boiler room drum and bass", "drum and bass mix", "hospital records
podcast", "liquid drum and bass mix", "boiler room house", "defected house mix", "house music dj set", "glitterbox mix",
"ambient mix", "ambient dj set", "nts ambient", "ambient music for sleep mix"). Each pick was checked through
`api-v2.soundcloud.com/tracks/<id>` with the `client_id` yt-dlp cached: 12 `MONETIZE`, 1 `ALLOW`,
|duration − full_duration| ≤ 0.66 s, and non-snipped `aac_160k`/`aac_96k` HLS for all 13; **all 13 resolved** through
`sudamp-dev resolve --source soundcloud` (`hls_aac_160k` from `playback.media-streaming.soundcloud.cloud`,
543–1036 ms) [measured]. Accounts: Boiler Room (`platform`), Defected Records, Glitterbox Recordings, Drum&BassArena,
Rinse FM, Skankandbass and Andrey Pushkarev (all SoundCloud-verified), Hiroshi Watanabe (`kaito`, his own account),
and two NTS archive accounts, "NTS Latest" (`user-202286394-991268468`) and "NTS 2024-2025"
(`user-643553014`): 11.6 k and 16 k tracks, both link `nts.live`, and the older one points to the newer. They are not
SoundCloud-verified, so the owner may want to confirm them.

**YouTube**: **10 of the 10-request budget used**, one yt-dlp run each through a guard script (budget, spacing,
bot-check stop; log in `/tmp/sudamp-curation2/yt/requests.log`), `--sleep-requests 3` inside the searches. Runs started
8–16 s apart; the shortest gap from one run's end to the next run's start was 4.8–5.7 s (#8 → #9; the log keeps
whole-second start times), every other gap ≥ 5.3 s. **No bot check, `LOGIN_REQUIRED` or 429** was seen.

| # | Request | Result |
|---|---|---|
| 1–3 | `ytsearch12/12/15:` "boiler room house music dj set", "drum and bass dj set boiler room", "ambient dj set" (flat) | House and DnB VODs from Boiler Room's official channel (0.5–56 M views); ambient from Moby's official channel, Humano Studios and Shai Space |
| 4–6 | `ytsearch15:` "drum and bass / house music / ambient music radio 24/7 live stream" (flat) | `is_live` channels: Hospital Records, Defected Records, Anjunachill (Anjuna's chill label) |
| 7–9 | `@hospitalrecords/live`, `@DefectedMusic/live`, `@anjunachill/live` with `sudamp-dev resolve --source youtube-live` | all live, audio-only HLS itag 234, 4780 / 2368 / 1975 ms |
| 10 | `S8DGyscGlKE` (Moby's ambient mix) with `sudamp-dev resolve --source youtube` | itag 251, 1509 ms |

`@hospitalrecords` runs two 24/7 DnB streams; `/live` currently picks "Forza Horizon 6: Hospital Records Radio". The
other 10 new VODs were flat-listed only (title, duration, channel, views), not resolved.

**Muted end-to-end check.** `sudamp-dev play --genre <g> --source radio,soundcloud,mixcloud --prefetch=false
--seconds 45 --next-every 14` (mixer volume 0, output muted, so no YouTube requests and no sound) for `house`,
`drum-and-bass` and `ambient`: exit 0, 12 starts, 0 failures, first-audio p50 1899 / 2072 / 2339 ms [measured].

**Curation choices (revision 2).** Same weights (mixes 1.0, `/live` 0.75, radio 0.5) and marquee convention (`creator`
is the DJ or broadcaster). Every mix is ≥ 55 minutes. Deep House gained Defected's "Deep House Chilled" (SoundCloud)
and two Anjunadeep Editions (Dusky, CRi); Techno gained two Drumcode Radio Live shows (Adam Beyer at Junction 2 and
Awakenings). Lo-fi already had 16. NTS is a broadcaster in both House and Ambient (different streams).

## Revision 1 (M1): three genres

`catalog/feed.json` revision 1 had 3 genres and 43 streams, all four resolver sources plus radio in every genre:

| Genre | Streams | YouTube VOD | YouTube `/live` | SoundCloud | Mixcloud | Radio (broadcasters) |
|---|---|---|---|---|---|---|
| Deep House (`deep-house`) | 13 | 4 | 1 | 2 | 3 | 3 (1.FM, Deep Radio, Technolovers.FM) |
| Techno (`techno`) | 14 | 3 | 1 | 3 | 3 | 4 (Sunshine Live, Techno.FM, Technolovers.FM, RauteMusik.FM) |
| Lo-fi (`lo-fi`) | 16 | 3 | 2 | 4 | 4 | 3 (REYFM, Hunter.FM, Hotmix Radio) |

## Engine section (unchanged in revision 2)

- `pin`: **yt-dlp 2026.10.21** (`releases/latest` on 2026-10-22, published 2026-10-21T21:54:37Z). `sha256`
  `2b5251788b36fcbc476568b4eea8cb239f0a775759456f2ff9344a437c52f000`, copied from that release's `SHA2-256SUMS` line for
  `yt-dlp_macos.zip`; the downloaded zip's `shasum -a 256` matched [measured]. `block` is empty.
- `sources`: youtube, soundcloud, mixcloud all `true`. `fastStartRank`: radio, soundcloud, mixcloud, youtube.
- `clients` and `formats`: DESIGN §6.2 defaults (`visionos`, `visionos,tv_samsung`; VOD, `/live`, SoundCloud, Mixcloud
  selectors). `extractorArgs`: `soundcloud:formats=hls_aac`.
- `mediaHosts`: `googlevideo.com`, `media-streaming.soundcloud.cloud`, `mixcloud.stream`. SoundCloud HLS playlists and
  segments came from `playback.media-streaming.soundcloud.cloud`; Mixcloud HLS/DASH from `aod.mixcloud.stream` and the
  progressive `http` format from `dl.mixcloud.stream` [measured]. `googlevideo.com` is YouTube's known media host; this
  run did not print YouTube media URLs, so it is [unverified here, R1 owns it].
- `canary`: `yt:bk6Xst6euQk` (Solomun, Boiler Room Tulum: 77 M views, resolved below) and `sc:platform/misskittin`
  (Boiler Room's official SoundCloud account).

## How each source was found and checked

All tools ran from `/tmp/sudamp-curation` with the official yt-dlp 2026.10.21 `yt-dlp_macos` (hash-verified, unpacked
with `ditto -x -k --noqtn`), `--ignore-config --no-plugin-dirs`, a private `--cache-dir`, no cookies, no accounts.

**Radio** (radio-browser.info, `de1.api.radio-browser.info` from `all.api.radio-browser.info/json/servers`, identifying
User-Agent). `/json/stations/bytag/<tag>?order=votes&reverse=true&hidebroken=true` for `deep house`, `techno`, `lofi`,
`lo-fi`, `lofi hip hop`, `chillhop`, `minimal techno`, plus `byname/technolovers`. No SomaFM station is listed (its
API is closed to third parties; ask first, DESIGN §7.3). Selection: HTTPS, a direct stream (no `.pls`/`.m3u`),
real host names that pass `RadioURLPolicy`, and broadcasters on independent infrastructure. Each URL was fetched twice
(32 KB, `curl -L -H 'Icy-MetaData: 1'`): every one answered 200 with `Content-Type: audio/mpeg`, and the body started
with an MPEG frame sync (`fffb…`), except Techno.FM, which joins mid-frame but shows 55 sync words 627 bytes apart
(192 kbps at 44.1 kHz) [measured]. Every host and redirect target resolved only to public addresses (`dig A/AAAA`):

| ID | URL | Redirects to | Notes |
|---|---|---|---|
| `radio:1fm-deep-house` | `https://strm112.1.fm/deephouse_mobile_mp3` | — | ICY name "1.FM Deep House Radio" |
| `radio:deep-radio` | `https://stream.deep.radio/hd` | `22603.live.streamtheworld.com:443` | "Deep Radio" (NL), 320 k |
| `radio:technolovers-deep-house` | `https://stream.technolovers.fm/deep-house` | `0nlineradio.stream39.radiohost.de` | 192 k |
| `radio:sunshine-live-techno` | `https://stream.sunshine-live.de/techno/mp3-192/stream.sunshine-live.de/` | `sunsl.streamabc.net` | "SUNSHINE LIVE - Techno" |
| `radio:techno-fm` | `https://stream.techno.fm/radio.mp3` | — | Icecast 2.4.4, 192 k |
| `radio:technolovers-techno` | `https://stream.technolovers.fm/techno` | `…radiohost.de` | 192 k |
| `radio:rautemusik-techno` | `https://streams.rautemusik.fm/techno/mp3-192/` | `rautemusik.stream37.radiohost.de` | "Techno" |
| `radio:reyfm-lofi` | `https://listen.reyfm.de/lofi_320kbps.mp3` | `reyfm.stream37.radiohost.de` | "#lofi \| by reyfm.de" |
| `radio:hunter-fm-lofi` | `https://live.hunter.fm/lofi_high` | — | "Hunter.FM - O Canal Lo-Fi" |
| `radio:hotmix-lofi` | `https://streaming.hotmixradio.com/hotmix-lofi-en-mp3` | — | "Hotmix LoFi" |

Several broadcasters (Technolovers, REYFM, RauteMusik) are served through the same radiohost.de streaming provider, so
each genre also includes at least two stations on different infrastructure (Deep House: 1.FM, StreamTheWorld; Techno:
streamabc, Techno.FM; Lo-fi: Hunter.FM, Hotmix). The coverage validator counts broadcasters by `creator`.

**Mixcloud** (`api.mixcloud.com/discover/<tag>/popular/?limit=25` for `deep-house`, `techno`, `lo-fi`, `lofi`,
`lofi-hip-hop`; no auth, ~60–100 ms). Preferred official label and DJ accounts (Defected Records, Anjunadeep, John
Digweed, Carl Cox) and long shows; refs had to match `^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$`, which rules out the many
non-ASCII slugs in the popular lists. All 10 were resolved once with yt-dlp (`-J`): every one returned formats and no
`restrictedReason`/exclusive error [measured]. Newer uploads offer `hls-192`; older ones only `hls-64`/`hls-6x`, `http`
and DASH, so `hls-192/http/bestaudio` falls back to `http` for them.

**SoundCloud** (`scsearch12:` flat searches: "deep house mix", "boiler room deep house", "techno mix", "boiler room
techno", "lofi hip hop mix", "lofi beats mix"). Each candidate was fully extracted once with yt-dlp (permalink, duration,
formats `hls_aac_96k,hls_aac_160k`), then checked against DESIGN §7.3's rule through `api-v2.soundcloud.com/tracks/<id>`
with the `client_id` yt-dlp had cached: every item has `policy` ALLOW or MONETIZE, |duration − full_duration| ≤ 0.7 s
(all < 2 s), and non-snipped `aac_160k`/`aac_96k` HLS transcodings [measured]. Boiler Room's official account is
`platform`. Solomun's Tulum set exists on SoundCloud too (`platform/solomun`) but was left out because the same set is
the YouTube canary.

**YouTube** — **12 of the 15-request budget used**, every yt-dlp invocation ≥ 5 s after the previous one and
`--sleep-requests 3` inside each:

| # | Request | Result |
|---|---|---|
| 1–3 | `ytsearch10:` "boiler room deep house dj set", "cercle techno dj set", "lofi hip hop mix 1 hour" (flat) | IDs, durations, official channels (Boiler Room, Cercle, Lofi Girl, Chillhop Music) |
| 4–5 | `ytsearch12:` "deep house radio 24/7 live stream", "techno radio 24/7 live stream" (flat) | `is_live` channels and handles |
| 6–9 | `@LofiGirl/live`, `@ChillhopMusic/live`, `@monstercatsilk/live`, `@bassportmusic/live` with the production `/live` flags | all `is_live`, audio-only HLS itag 234 |
| 10–12 | `bk6Xst6euQk`, `vqz8c4ZP3Wg`, `CFGLoQIhmow` with the production VOD flags (tier 1, `visionos`, no JS runtime) | all `public`, itag 251 (webm/opus), ~7.4 s each including the 3 s request sleeps |

No bot-check or 429 was seen. The other seven VODs were only flat-listed (title, duration, channel, views), not
resolved: they are long-standing official uploads (Boiler Room, Cercle, Lofi Girl, Chillhop Music) with 1–137 M views,
but their playability is [unverified, M7 `catalog-tool probe`].

## Curation choices

- `creator` is the DJ or broadcaster and `title` the set or station, so the marquee reads `[TECHNO] ANNA - VINYL DJ SET…`.
- Weights: mixes 1.0, 24/7 `/live` 0.75, radio 0.5. Radio still wins fast-start (it is "ready"); later in a bag the
  lower weight lets mixes come first more often.
- Every mix is ≥ 50 minutes (the test enforces ≥ 40). No Go+ previews, no SomaFM, no cookies.
- `expiresAt` is 2027-04-22; bundled documents never expire (DESIGN §7.2), so it only matters once M7 publishes it.

## Not verified, and follow-ups

- YouTube VODs not resolved (budget): seven from revision 1 and ten from revision 2 (only Moby's ambient mix was
  resolved); geo-restrictions are invisible from one location. M7's `catalog-tool probe` should resolve them all.
- Revision 2's genres (House, Drum & Bass, Ambient) and IDs (`house`, `drum-and-bass`, `ambient`) are provisional
  until the owner approves them; renaming an ID later orphans favourites and history for that genre.
- Two Ambient SoundCloud items come from NTS archive accounts without SoundCloud's verified badge (see above).
- `@hospitalrecords/live` picks one of two concurrent Hospital streams; `/live` channels can switch or end.
- `dnbradio.com` was in maintenance (503) at check time; the stream itself passed both checks.
- Mixcloud's free-listener replay limits (`repeat_play`) will hit skip-heavy listening; the resolver classes them
  `unavailable` (DESIGN §6.4). Mixcloud remains included pending the owner's DESIGN §13 decision.
- Radio streams were checked at one point in time; M7's `catalog-tool probe` re-checks the feed before each release.
- Reproduce: radio-browser and Mixcloud queries above with `curl`; yt-dlp with
  `--ignore-config --no-plugin-dirs --flat-playlist -J "scsearch15:<q>"`; revision 2 was generated from revision 1
  plus the curation notes by a one-off script (`/tmp/sudamp-curation2/scripts/gen-feed.py`, which keeps the engine
  block and the revision-1 lines verbatim) and is edited by hand from here until M7's `catalog-tool build`.
