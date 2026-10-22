# Test feed key (public by design)

`test-ed25519.key` / `test-ed25519.pub` are a **test-only** Ed25519 keypair for the remote feed (DESIGN §7.2,
PLAN M7). The private half is committed on purpose so live tests and CI can sign scratch feeds without the
production key or Keychain access. Only **debug** builds trust it (`FeedTrust.testKey`, compiled in under `#if DEBUG`);
release builds trust only `FeedTrust.productionKeys`, so a feed signed with this key is never accepted by a release.

Never use this key for a published feed. Formats are documented in `docs/catalog.md` ("Keys and signatures").
