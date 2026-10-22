# Feed fixtures (PLAN M7)

Test feeds signed with the committed **test** key (`Fixtures/keys/test-ed25519.key`), which only debug builds trust.
Point a debug build at one with `SUDAMP_FEED_URL` (debug builds allow `http://127.0.0.1`).

| Fixture | Content | Use |
|---|---|---|
| `block-latest/` | revision 3: the revision-2 catalog, `engine.block` = `["2026.10.21"]` (upstream's latest on 2026-10-22), `engine.pin` = `2026.08.19` (SHA-256 from upstream's `SHA2-256SUMS`), `expiresAt` 2027-04-22 | PLAN M7 "a test feed whose `block` lists upstream's latest release installs `pin`" |

`serve.py` serves a directory with GitHub-Pages-like ETags and 304s, or (`--blackhole`) never answers:

```sh
python3 -I Fixtures/feeds/serve.py Fixtures/feeds/block-latest --port 18471 --log /tmp/feed-requests.jsonl &
P=$(mktemp -d)
SUDAMP_FEED_URL=http://127.0.0.1:18471/feed.json .build/debug/catalog-tool fetch --profile "$P" --choose
jq -c 'select(.event | test("^(feed|engine)\\.")) | {event, status, outcome, version, reason}' "$P/Logs/metrics.jsonl"
```

`block-latest` stops being useful when upstream ships a newer release (then 2026.10.21 is no longer "latest"; rebuild
it with a new `block`), and stops verifying as current after its `expiresAt`. Regenerate: copy `catalog/`'s sources to
a scratch directory, edit `release.json`/`engine.json`, `catalog-tool build <dir>`, then
`catalog-tool sign --key Fixtures/keys/test-ed25519.key <dir>/feed.json`.
