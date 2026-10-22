# Credits, About and third-party notices (PLAN M7 credits; M8 licence-compliance prep)

*2026-10-22 · agent: polish · scratch path `.build-polish` · no Developer ID needed for any of this*

**Result.** `scripts/check-notices.sh` computes what sudamp actually links from MPVKit 1.0.0 (29 binary targets,
cross-checked against the linker map: 28 contribute object files, `Libssl` none), generates
`THIRD_PARTY_NOTICES.md` (1,616 lines: every linked library with version, licence as used, copyright, source
archive and notice text; 7 system libraries; `qjs`; the vendored mpv headers; the AndAmp skins; the 5 MIT holders
from PROVENANCE.md; LGPL-2.1, LGPL-3.0 and Apache-2.0 texts), exits 0 on the current link set and 1 when any entry
is missing or out of date. `scripts/mirror-sources.sh` lists the 36 corresponding-source archives a release must
attach; all 36 URLs answer 200. `CREDITS.md` is the human-readable list. `AboutWindow.show(skin:)` is a native About
window with the stance, licence, credits and viewers for LICENSE, CREDITS.md and THIRD_PARTY_NOTICES.md; it is
built and unit-checked but not yet reachable from the menus (one-line hookup requested).

## What sudamp links (measured)

`swift package dump-package` on a copy of MPVKit's manifest (the checkout matching Package.resolved, revision
`288527df…`) gives the closure of the `MPVKit` product (the LGPL build; `MPVKit-GPL` and `Libsmbclient` are not
used): `_MPVKit` → `Libmpv`, `_FFmpeg`, `Libuchardet`, `Libbluray`, `Libluajit` (macOS); `_FFmpeg` → 25 more.
Versions come from MPVKit's build scripts and those of the `mpvkit/*-build` repositories at the tags its
`Package.swift` pins, and were confirmed in the binaries where they say so:

| Evidence in the static library | Component |
|---|---|
| `mpv v0.41.0-dirty` (the patches), configure line with `-Dgpl=false` | mpv |
| `FFmpeg version n8.1.2`; configure line with `--enable-version3`, no `--enable-gpl` | FFmpeg (LGPL-3.0-or-later) |
| `OpenSSL 3.3.5 30 Sep 2025` | OpenSSL |
| source paths `gnutls-3.8.11`, `nettle-nettle_3.10_release_20240616`, `gmp-v6.2.1` | GnuTLS, Nettle, GMP |
| `14.2.0`; `(GNU FriBidi) 1.0.16`; libass `0.17.5-0-g4a05d812` | HarfBuzz, FriBidi, libass |
| `LuaJIT 2.1.1784580905` = committer time of LuaJIT `2460b3ff` (2026-07-20) | LuaJIT (v2.1 is a rolling branch) |
| `1.5.3-0-gb546257`; `libplacebo-v7.360.1`; `libbluray-1.4.0`; `1.2.1` | dav1d, libplacebo, libbluray, uavs3d |
| Rust objects `std core alloc compiler_builtins panic_abort addr2line gimli object rustc_demangle anyhow bitvec_helpers` | inside `Libdovi` |
| glslang/SPIRV-Tools objects; `libMoltenVK.a-arm64-master.o` with SPIRV-Cross | shaderc (combined), MoltenVK |

Licence choices recorded in the notices: mpv LGPL-2.1-or-later (built without GPL files); FFmpeg LGPL-3.0-or-later
(version3); GnuTLS, FriBidi, libbluray, libplacebo LGPL-2.1-or-later; Nettle and GMP dual-licensed, used under
LGPL-3.0-or-later; uchardet tri-licensed, used under LGPL-2.1-or-later; **FreeType** dual FTL/GPL-2.0-or-later,
used under the GPL option (as GPL-3.0-or-later, so no extra text) with its credit line kept; OpenSSL, MoltenVK,
shaderc Apache-2.0; libass ISC; dav1d BSD-2-Clause; uavs3d BSD-3-Clause; HarfBuzz "Old MIT"; libunibreak zlib;
lcms2, libdovi, LuaJIT, QuickJS-NG MIT. Permissive notices are copied verbatim from upstream at the pinned version.
The 7 system libraries MPVKit links (`bz2 c++ expat iconv resolv xml2 z`) ship with macOS and are listed, not
redistributed.

## check-notices.sh

- **Default (check, offline):** fails (exit 1, naming the entry) if a binary target in the link set has no row, if
  a row's "Built by" (release-asset repo and tag) differs from MPVKit's manifest (a version change), if the linker
  map shows objects from a library outside the link set, if a system library, `qjs` (version from
  `scripts/fetch-qjs.sh`), the mpv headers (version from `vendor/README.md`), an AndAmp skin, Sparkle (once it is a
  dependency) or a PROVENANCE.md "MIT ©" holder has no entry, if a licence text is missing, or if the file is stale
  (an `inputs-sha256` over the script, Package.resolved's revision, the link set and the other inputs). Exit 2 for
  environment problems (no checkout; run `swift build` first).
- `--generate` rewrites the file deterministically (the Apache-2.0 text is fetched once into
  `~/Library/Caches/sudamp-dev/notices`, sha256-pinned `cfc7749b…`; LGPL-2.1 comes from `Sources/SudampAO/vendor`,
  LGPL-3.0 from MPVKit's own LICENSE). `--link-set` prints the set with object counts; `--list-sources` feeds
  mirror-sources.sh; `--require-sources DIR` is the M8 "every library has a mirrored archive" check.
- Run time 1–3 s (most of it `dump-package`).

## mirror-sources.sh (prototype)

Dry run by default: the sudamp tag (`git archive`), MPVKit 1.0.0's tag archive (build scripts and patches
0001–0003), the 13 `mpvkit/*-build` repositories at the tags that built a linked target (the LGPL's "scripts used
to control compilation"), the 21 upstream source archives, and QuickJS-NG: 36 archives. `--verify` HEADs each
(36/36 answered 200, 2026-10-22); `--fetch DIR` downloads and writes SHA256SUMS. It refuses `--upload`; nothing
was downloaded or uploaded here.

## Gates

| Gate | Command / evidence | Result |
|---|---|---|
| AboutWindow compiles, zero new warnings | `swift build --scratch-path .build-polish --build-tests` after touching every changed file; `scripts/check-warnings.sh` on the log | **GO** |
| AboutWindow content unit-checked | `AboutWindowTests` (5): stance, licence, all required credits (Webamp, Bitamp, wamp, macamp, MacAmp, AndAmp CC BY 4.0, mpv/FFmpeg, QuickJS-NG, yt-dlp "never bundled"), "Winamp" only nominative and no llama, version/build from a bundle, current-skin credit, documents from the bundle or the repository, the built window's labels and buttons | **GO** |
| AboutWindow seen | `SUDAMP_ABOUT_SNAPSHOT=/tmp/about.png swift test … --filter AboutWindowSnapshot` (offscreen, light and dark): layout checked by eye | **GO** (offscreen only) |
| AboutWindow in the running app | needs the AppMenus hookup (requested) | **NOT-RUN** |
| check-notices.sh exits 0 on the current link set | `scripts/check-notices.sh` → `OK (29 MPVKit binary targets, 7 system libraries, qjs, mpv headers, 2 skins, 5 MIT notices; linker map cross-checked)`; `ThirdPartyNoticesTests.committedNoticesCoverTheLinkSet` | **GO** |
| …and non-zero when an entry is removed | `ThirdPartyNoticesTests.removingAnEntryFails` (7 cases: `Libmpv`, `Libavcodec`, `Libssl`, `libz`, `qjs`, `AndAmp-Dark.wsz`, MIT © 2015 Jordan Eldredge), `versionDriftFromMPVKitFails` | **GO** (exit 1, entry named) |
| mirror-sources lists every archive | dry run 36; `--verify` 36/36 HTTP 200 | **GO** (prototype; no fetch, no upload) |

## Open for M8

- Bundle the files: the app should carry `LICENSE`, `CREDITS.md` and `THIRD_PARTY_NOTICES.md` in
  `Contents/Resources` (requested change to `scripts/bundle.sh`); until then About shows them only when run from a
  checkout.
- Notice texts still to add: glslang's and SPIRV-Headers' (inside shaderc), glad and fast_float (inside
  libplacebo), the Rust crates' Apache/MIT notices are covered by the Apache text but their copyright lines are not
  listed one by one.
- Pin the uavs3d upstream commit libuavs3d-build 1.2.1-fix used (its script says source "1.0"; the library reports
  1.2.1); LuaJIT is pinned by commit.
- Releases must attach the archives (M8 with the owner's account) and `check-notices.sh --require-sources` must
  pass on that directory; consider a written offer as a fallback.
- Run `scripts/check-notices.sh` in CI after the build, and as part of `make test` or a `make notices` target.
- `Package.swift` writes the linker map to `.build/sudamp-link.map` from every scratch path; any agent's build
  (this one included) overwrites the shared map until the next `make build`.
