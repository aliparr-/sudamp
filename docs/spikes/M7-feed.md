# M7: remote feed and catalog-tool

*2026-10-22 · agent: feeds · scratch path `.build-feeds` (plus a symlinked subset package in `/tmp/feeds-agent/pkg`
while another agent's Shell file was mid-edit) · status: Feeds remote path, `<profile>/feed/` cache, `catalog-tool` and
the `catalog/` source layout done and verified against local HTTP servers. **Not yet wired into the repo's app**: the
integration (Resolver, Playback, Shell) is a requested shared change; it was applied to a throwaway copy of the repo,
which built warning-free, passed all 661 tests and ran the PLAN M7 app checks below. No GitHub remote exists, so
nothing is hosted.*

Machine: macOS 27.0.1, Apple M5 Pro, Command Line Tools only, Swift 6.4, one UK residential connection.

## What exists

| Item | Where | State |
|---|---|---|
| Ed25519 detached signatures (CryptoKit) | `Sources/Feeds/FeedSignature.swift` | `.sig` = 64 raw bytes (base64 text also read); key files `ed25519-{private,public}:<base64>` |
| Trusted keys, feed URL | `Sources/Feeds/FeedTrust.swift` | `FeedTrust.productionKeys` = `[]` (≤ 2, rotation); test key only under `#if DEBUG`; `FeedEndpoint.production` = nil; debug `SUDAMP_FEED_URL` |
| Fetch | `Sources/Feeds/RemoteFeedClient.swift` | URLSession, `If-None-Match`/ETag, 304, 2 MiB cap (stops reading), timeouts, HTTPS only (+ loopback HTTP in debug), redirect guard, `User-Agent: sudamp/<ver>`, `Accept-Language: *`, no cookies/cache/credentials |
| Cache | `Sources/Feeds/FeedCache.swift` | `<profile>/feed/feed.json`, `feed.json.sig`, `meta.json {etag, fetchedAt, revision}`; atomic writes, meta last; re-verified on every read |
| Selection | `Sources/Feeds/ActiveFeed.swift` | `ActiveFeedSelector` + `FeedRejection` (signature, invalid, rollback, expired, minAppVersion) |
| Service | `Sources/Feeds/FeedService.swift` | `refresh(budget:)` → `FeedRefreshResult(active, outcome, changed, ms)`; single flight; `launchRefresh(budget:)` (once per process, shared by the launch task and the engine gate, budget counted from the first call); late completion → `setOnChange`; `runPeriodicRefresh()` (12 h, 1 h after a failure, `TimeSource` + injectable sleeper); metrics `feed.fetched`, `feed.status`, `feed.rejected` |
| Catalog sources | `catalog/{release,engine,pins}.json`, `catalog/genres/*.json` | migrated from the hand-edited `feed.json` with `catalog-tool split`; `build` reproduces the shipped `feed.json` byte-for-byte |
| Build / lint model | `Sources/Catalog/Curation/` | `OrderedJSON` (strict, order- and literal-preserving), `CatalogSource`, `CatalogBuilder`, `CatalogLint`, `AudioSniffer` |
| `catalog-tool` | `Sources/catalog-tool/` | `build`, `lint`, `sign`, `verify`, `keygen`, `probe`, `discover`, `fetch` (headless launch harness), `bump`, `split` |
| Fixtures | `Fixtures/keys/test-ed25519.{key,pub}`, `Fixtures/feeds/block-latest/`, `Fixtures/feeds/serve.py` | test keypair; signed r3 feed blocking 2026.10.21 and pinning 2026.08.19; ETag/304 server and `--blackhole` |
| How-to | `docs/catalog.md` | layout, adding streams, lint rules, probe/discover, publishing, keys |

## Decisions

- **Signature file.** Raw 64-byte Ed25519 over the exact `feed.json` bytes (DESIGN §7.2 "raw detached"); readers also
  accept the same bytes as one base64 line, for hosts or editors that mangle binary (lengths 64 vs 88 can't collide).
  CryptoKit's signatures are randomised, so `sign` is not byte-reproducible; `build` is.
- **Trust.** `FeedTrust.embedded` = production keys (+ the committed test key in debug builds). No production key ⇒
  `FeedService` disables fetching (`feed.status` `disabled`, "no trusted feed key in this build") and also ignores any
  cached copy, so release builds are bundled-only until the owner generates the key (`catalog-tool keygen`) before M8.
- **What gets cached.** Only documents that verify, decode, are unexpired, allow this app version and have
  `revision ≥` the verified cached revision. Rejected documents never replace the cache, so a bad publish can't erase
  a good copy. A cached copy that fails re-verification is ignored (not deleted: another build with other keys may
  share the profile) and its ETag is not sent, so the next fetch downloads a fresh body instead of a 304.
- **Anti-rollback floor** = the verified cached document's revision. **Expiry** applies to cached and fetched
  documents (both came from the host), never to the bundled one; every refresh re-chooses, so a cached copy that
  expires while the host is unreachable falls back to the bundled one.
- **Engine strings** of a fetched document are validated over the *active* document's engine section (DESIGN §7.2:
  "a failing value keeps its previous value"); a cached copy at launch is validated over the bundled one's.
- **Budget.** `refresh(budget:)` returns at the budget with `.timedOut` and the best local document; the fetch keeps
  running (client timeout 20 s) and a later change arrives through `setOnChange`. A second caller (the engine gate)
  joins the same fetch. `launchRefresh` goes further: the app's launch task and the engine gate share one fetch and
  one budget even when the gate asks after the fetch finished (a first integrated run made a second, 304 request from
  the gate; now one request). Task.sleep's default leeway made a 5 s budget return after **5265 ms**; an explicit 5 ms
  tolerance brought it to **5002–5010 ms** [measured].
- **Schedule.** Launch, then `fetchedAt + 12 h`; after a failed or rejected attempt, `+ 1 h` (not specified by DESIGN;
  one conditional GET an hour while the host is down). The loop sleeps in ≤ 15 min steps so wall-clock changes,
  `SUDAMP_CLOCK_OFFSET` and sleep/wake are noticed.
- **No identifiers.** Live request headers were `Host`, `Accept: */*`, `Accept-Encoding: gzip, deflate`,
  `Connection`, `User-Agent: sudamp/0.1.0-dev` and, at first, **`Accept-Language: en-GB,en;q=0.9`** (CFNetwork adds
  the user's locale). The client now sends `Accept-Language: *` [measured after the fix].
- **Source layout.** One file per genre so curation diffs are small; streams keep their one-line layout; `genres` is
  implied by the file; the build writes keys in a fixed order (so key order in sources doesn't matter) but keeps number
  spellings (`1.0` stays `1.0`). The pinned version's SHA-256 lives in `catalog/pins.json` (a lock file written by
  `build` from upstream's `SHA2-256SUMS`), so `build` is offline and deterministic after the first time.
- **lint ⊇ the app's decoder.** `lint` fails on anything the decoder would drop or repair (and on unknown keys, which
  the decoder ignores), plus the 1.0 coverage rule, canary, expiry, duplicates and policy; `build` refuses on errors.

## Unit tests (`make test` scope; all pass)

FeedsTests (31; 26 new): `launchRefreshRunsOnceAndItsBudgetCountsFromTheFirstCaller`, `fetchedVerifiedAndCachedThenReadBackAtLaunch`, `notModifiedUpdatesFetchedAtOnly`,
`rejectedDocumentsKeepThePreviousActiveDocument` (tampered byte, wrong key, lower revision, expired, minAppVersion
too high, bad JSON, schema 2), `expiredFetchedFallsBackToCachedThenBundled`, `cachedCopyExpiringWhileOfflineFallsBackToBundled`,
`bundledFeedPastExpiresAtStillPlays`, `highestValidRevisionWinsAndBundledWinsTies`,
`engineStringsFailingValidationKeepTheirPreviousValues` (`;` in a client list, a format starting with `-`, a bad
extractor arg, media host, pin and block), `launchBudgetFallsBackAndALateFetchStillLands`,
`hostThatNeverAnswersFallsBackWithinTheBudget`, `concurrentRefreshesShareOneFetch`, `disabledWithoutURLOrTrustedKeys`,
`unverifiableCacheIsIgnoredAndItsETagNotSent`, `feedScheduleRule`, `periodicRefreshRunsEveryTwelveHours` (fake clock),
`committedTestKeypairMatchesTheEmbeddedTestKey`, `signatureVerifiesAndRejectsTamperingAndWrongKeys`,
`signatureFileFormats`, `keyFileFormats`, `blockLatestFixtureIsSignedAndPinsAnOlderRelease`, `feedURLPolicy`,
`signatureURLIsNextToTheFeed`, `fetchSendsConditionalRequestsWithoutIdentifiers`, `fetchFailuresAreTyped` (500, 404,
oversized with and without Content-Length, redirect to HTTP not followed, hang → timeout), `redirectToHTTPSIsFollowed`.
The HTTP tests use an in-process `URLProtocol` stub routed by host name (`Tests/FeedsTests/StubFeedServer.swift`).

CatalogTests (42; 9 new): `buildReproducesTheShippedFeedByteForByte` (two builds identical, equal to
`catalog/feed.json`), `splitAndBuildRoundTrip`, `buildNormalisesKeyOrderAndFillsThePin`, `lintPassesOnTheShippedCatalog`,
`lintFixturePassesCleanly`, `lintReportsEachRule` (json, schema, canonical, duplicate, radioURL, coverage, engine,
canary, expiry, policy, stale), `orderedJSONKeepsOrderAndSpelling`, `orderedJSONIsStrict`, `audioSnifferFindsChainedFrames`.

Full suite in `.build-feeds`: 659 tests, 0 failures; `scripts/check-warnings.sh` clean; `scripts/count-escapes.sh`
3 total / 0 unjustified (none added in Sources; one justified `nonisolated(unsafe)` in the test stub).

## Live checks (local servers on 127.0.0.1; debug `catalog-tool`)

**1. The real catalog.** `catalog-tool split catalog/feed.json --out catalog` wrote the sources; `catalog-tool build
--check` → "feed.json is up to date: r2, 6 genres, 99 streams, 28938 bytes, sha256 dd2e771e…a56c3d" (the file is
unchanged, `cmp` identical); `catalog-tool lint catalog/` → **0 errors, 0 warnings**; with `--dns` (every radio host
resolved, public addresses only) also 0/0. `build --check` takes 0.22 s.

**2. A test feed whose `block` lists upstream's latest.** `releases/latest` → 2026.10.21 on 2026-10-22. A scratch copy
of the sources with `revision` 3, `pin` `2026.08.19`, `block` `["2026.10.21"]`: `build` fetched the pin's checksum,
"yt-dlp 2026.08.19 yt-dlp_macos.zip sha256 07e54b08…28a6d8 (from upstream SHA2-256SUMS)" (cross-checked with `curl`
of the same `SHA2-256SUMS`), wrote `pins.json`, and a second build, `--check` and `--offline` produced identical bytes.
`lint` 0/0; `sign --key Fixtures/keys/test-ed25519.key` → 64-byte `.sig`, key id `64c79b4052cfa918` ("the TEST key");
`verify --pub …test-ed25519.pub` and `--embedded` exit 0; `verify --production` exits 1 (no production key); the
base64 form of the signature also verifies. This feed is committed as `Fixtures/feeds/block-latest/`.

**3. Fetched, verified, cached, then the engine choice** (`SUDAMP_FEED_URL=http://127.0.0.1:18471/feed.json
catalog-tool fetch --profile <fresh mktemp> --choose`, an ETag server): outcome `updated`, active r3 (`fetched`),
refresh 25 ms; `<profile>/feed/feed.json` byte-identical to the served file, `meta.json` `{etag, fetchedAt, revision: 3}`;
EngineStore chose **2026.08.19, reason `pin`**. `metrics.jsonl` order: `feed.fetched` (status 200, r3) at +52 ms after
launch, `feed.status` (`updated`), `engine.choose` (2026.08.19, pin) at +455 ms (the `_update_spec` request).
Each `catalog-tool fetch` is a new process, so it uses `refresh`, not `launchRefresh`. Repeated
with the committed fixture and `Fixtures/feeds/serve.py`: 29 ms, `engine.choose` at +526 ms.

**4. Second launch → 304.** Same profile: the client sent `If-None-Match: "ca7553bbd9d17ca5"`, the server answered
304 and was not asked for the signature; outcome `notModified`, refresh 4 ms, active r3 (`cached`); `meta.json`
`fetchedAt` moved, etag and revision unchanged; `feed.fetched` and `feed.status` both have `status: 304`;
`engine.choose` still 2026.08.19 (pin) at +108 ms.

**5. A host that never answers** (`serve.py --blackhole`, fresh profile, `--budget 5`): outcome `timedOut`, active
r2 (`bundled`), refresh 5010 / 5002 / 5010 / 5010 ms; `engine.choose` **2026.10.21 (the bundled pin)** at
5126 / 5110 / 5130 / 5114 ms after process start (≤ 5.5 s) [4 runs after the tolerance fix; the one run before it:
refresh 5265 ms, `engine.choose` at 5367 ms].

**6. Rejections, live.** Tampered byte in a served title → `rejected: signature …`, active bundled r2; signed with
another key (`keygen`) → `signature`; cached r3 and the host serving the repo's r2 signed with the test key →
`rollback` ("revision 2 is below the cached revision 3"), active stays cached r3; an expired r4 → `expired`, active
cached r3 on that profile and bundled r2 on a fresh one. `feed.rejected` carried `reason` and `revision` each time.

**7. `catalog-tool probe`** (pinned yt-dlp 2026.10.21 installed into a scratch profile by `--install-engine`):
- `--source radio,soundcloud,mixcloud --limit 20`: **20/20 passed** (SoundCloud 8: `hls_aac_160k` from
  `playback.media-streaming.soundcloud.cloud`, 570–1011 ms, playlist 200; Mixcloud 6: `hls-192` from
  `aod.mixcloud.stream` 762–1197 ms, or progressive `http` from `dl.mixcloud.stream` with a 206 range GET; radio 6:
  HTTP 200 `audio/mpeg`, 14–20 chained MPEG frames, 427–1969 ms). Resolved durations matched the feed within 1 s.
- `--source youtube,youtube-live --limit 5 --youtube-limit 5`: **5/5 passed**, all tier 1 (`visionos`, no JS
  runtime), itag 251, 1433 / 1543 / 1785 / 3566 / 4256 ms, 64 KB range GET → 206 from `rr*---sn-*.googlevideo.com`;
  durations within 1 s of the feed. The five happened to be VODs (the cross-section takes each genre's first YouTube
  item); no `/live` channel was probed.

**8. `catalog-tool discover --genre "deep house"`** (limit 3; one radio-browser server list + one station query per
run, one Mixcloud discover call, one `scsearch`): 3 verified radio candidates (HTTP 200, `audio/mpeg`, 26 chained
frames), 3 non-exclusive Mixcloud mixes ≥ 40 min, 3 SoundCloud mixes; items already in the catalog are left out.
Its output is for review only: the radio candidates were mainstream "TOP 100" streams that a curator would reject.

**9. The app, integrated (throwaway copy of the repo with the requested Resolver/Playback/Shell changes; its own
`.build` and `build-feeds/sudamp.app`, launched directly with `--profile <mktemp> --mute --plain --automation`, never
through LaunchServices).** Times are from the `app.launch` metric:
- *Fresh profile, `block-latest` served:* `feed.fetched` 200 r3 at +33 ms, `feed.applied` 2 → 3 at +61 ms, radio
  `pick` at +65 ms (`radio:deep-radio`, TTFA 1276 ms), `engine.choose` **2026.08.19, reason `pin`** at +129 ms,
  `engine.install` 2026.08.19 in 3.1 s, `engine.ready` at +3.2 s. One feed request and one signature request. The
  automation dump during install: radio playing, engine 32% downloaded, mixer volume 0, output muted.
- *Second launch, same profile:* the cached r3 applied before any traffic, then `feed.fetched`/`feed.status`
  **status 304** at +11 ms (`If-None-Match` sent, `Accept-Language: *`); the engine was already ready (no choice).
- *Host that never answers (`serve.py --blackhole`), fresh profiles:* radio `pick` at +84 ms (TTFA 1300 / 1308 /
  1023 ms) while the refresh waited; one `feed.status` `timedOut` at +5008 ms; `engine.choose` **2026.10.21 (the
  bundled pin)** at +5088 / +5109 / +5085 ms after `app.launch`. Measured from `exec`: 5.23 s on a warm launch, 5.74 s
  on the first launch of a freshly signed binary, whose `app.launch` came 626 ms after `exec` (the 5 s budget starts
  when `AppContext` creates the `FeedService`).

## Network use

YouTube: **5 resolves** (each yt-dlp run counted; tier 2 only with `--ladder`, not used) plus their 5 googlevideo range
GETs, started ≥ 8 s apart (end-to-start ≥ 8 s); **no bot-check, `LOGIN_REQUIRED` or 429**. SoundCloud 8 resolves + 1
`scsearch`; Mixcloud 6 resolves + 1 API call; radio-browser 6 calls; ~15 stream checks on radio hosts; GitHub ~16
requests (`releases/latest`, `releases.atom`, two `SHA2-256SUMS`, one engine install, `_update_spec` per `--choose`).

## Not done, open

- **App integration** (Resolver/Playback/Shell are not this agent's): `PlaybackController` takes a swappable feed and
  gates its first engine choice on the launch refresh; `AppContext` owns a `FeedService`, runs the launch refresh in
  parallel with radio and the 12 h loop, and applies `setOnChange`. The exact diff and two Playback tests are in the
  report's requested shared changes; until they land, the repo's app is bundled-only as before. The app-level checks
  above ran on a throwaway integrated copy, not on the repo's build.
- From `exec`, a cold first launch reached `engine.choose` at 5.74 s (PLAN says ≤ 5.5 s "after launch"); measured from
  `app.launch` it is 5.09–5.11 s. If the stricter reading matters, Shell can pass `budget: 5 s − (time since process
  start)`.
- **Signed bundled snapshot.** DESIGN §7.2 wants the bundled copy signed too; there is no production key, and the
  bundle script doesn't copy `feed.json.sig`. The bundled copy stays trusted through the app's code signature.
- **Hosting**: GitHub Pages and `FeedEndpoint.production` wait for the owner's remote/domain; the production key for
  `FeedTrust.productionKeys` waits for the owner (before M8). The Keychain route for `sign --key -` is documented, not
  tested (this agent never touches the user's Keychain).
- **Full probe**: 25 of 99 items were probed (YouTube budget). The owner should run the full YouTube probe over a few
  days (`--youtube-limit` ~20 per run) before beta; `/live` channels are unprobed here.
- `discover` doesn't automate the SoundCloud policy/`full_duration` check (needs SoundCloud's api-v2 `client_id`) or
  Mixcloud's `restrictedReason` (run `probe` on candidates); its JSON says so per item.
- `minAppVersion`, malformed/oversized responses and engine-string fallback were verified by unit tests only.
