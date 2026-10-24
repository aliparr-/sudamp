# sudamp's website

One static page: no build step, no dependencies, no trackers. Open it through any web server (ES modules don't load
from `file://`):

```sh
python3 -m http.server 8000 -d site    # then http://localhost:8000
```

Any static host works (GitHub Pages, Netlify, an S3 bucket): upload the folder as it is.

## Before it goes live

- **Download link.** `DOWNLOAD_URL` at the top of `js/main.js` (and the mega button's `href` in `index.html`) points
  at `https://github.com/aliparr-/sudamp/releases/latest`. There is no release yet, so it lands on an empty page
  until one is published.
- **Share image.** `og:image` is relative (`media/og.jpg`); most social sites want an absolute URL, so set it to the
  real domain.

## What's where

| Path | What |
|---|---|
| `index.html` | The page: hero with a working player, how it works, visualisers, skins, Toast, download |
| `css/style.css` | All of the styling. Colours and fonts are at the top |
| `js/main.js` | The player, the gallery, skins, Toast, the toaster, reveals and tapes |
| `js/groove.js` | Toast's theme tune, synthesised with Web Audio, and the clock the page dances to |
| `js/sprites.js` | Toast's sprite sheets, the pixel toaster and the menu bar glyph |
| `fonts/` | Bricolage Grotesque, Instrument Serif and Silkscreen (SIL OFL, see `fonts/LICENSE.md`) |
| `media/scenes/` | A four-bar clip and poster of each of the 28 visualiser scenes, plus Synthwave with VHS and Kaleidoscope |
| `media/toast/` | The Dancing Toast's sprite sheets in five looks (46×46 pixels a frame) |
| `media/classic/` | The classic skins' windows at 1x, and how to redraw their spectrum |
| `tools/` | How the media was made (not needed to serve the page) |

## Everything is real

The clips, Toast's dance and the classic windows come from the app's own rendering code, not mock-ups:

- `tools/render-media.sh` rebuilds all of `media/` from `Sources/ModernUI/Visualizer` with the Swift in
  `.swift-version` (build the app first: `make app`). It plays each scene through the analyser frames of the
  preview's synthesised music (`sudamp --modern-preview --dump-frames`), exactly as the app would.
- `tools/render-classic.sh` renders the classic windows with `sudamp --snapshot`.

The page's music is the same 124 bpm, sixteen-bar arrangement the clips were rendered from, so when it plays, the
pictures land on the beat: Toast's frame is worked out from the audio clock, and the clips are nudged to stay in time.
Picking a genre changes the flavour, not the tempo.

## Checking it without a screen

`tools/shoot.swift` loads the page in WebKit offscreen and saves screenshots, which works even when the Mac's screen
is locked. WebKit snapshots don't draw `backdrop-filter`, so glass looks flatter there than in Safari.

```sh
swiftc -O site/tools/shoot.swift -o /tmp/shoot
/tmp/shoot http://localhost:8000/ /tmp/hero.png --width 1440 --height 900 --wait 2.5
```
