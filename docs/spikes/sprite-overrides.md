# Sprite table overrides

`scripts/gen-sprites.py` generates `Sources/SkinKit/Generated/SpriteTable.swift` from Webamp's
`packages/webamp/js/skinSprites.ts` at commit `7734cd3c7cf144bab2d8614ce9f9ba2ff21e163e` (source SHA-256
`44ce6dc4f62a759ce155474584693990424c83b65544a3a633b2478ac22e9267`). Its `OVERRIDES` table may patch individual
sprites; every override must be listed here as a table row starting with `` | `SPRITE_NAME` | ``, which
`SpriteTableTests` reads to skip it in the equality check against `spikes/skins-tools/webamp_sprites.json`.

**Current overrides: none.** All 212 rects equal Webamp's (tested).

The known differences between Webamp's sprite rects and what a window actually shows are draw-size differences,
so they live in the layout tables (`Sources/SkinKit/Render/Layout.swift`), not here:

- `MAIN_NEXT_BUTTON` is 23 px wide in the table but Webamp's CSS draws `#next` 22 px wide (the 23rd column is
  eject's first column on the sheet). The composer draws 22 px.
- `MAIN_SHUFFLE_BUTTON*` are 47 px wide; repeat's draw rect starts at x=210 and covers the 47th column, so the
  composer draws 46 px (Bitamp's choice; the pixels on screen are identical to Webamp's).
- `MAIN_WORKING_INDICATOR`/`MAIN_NOT_WORKING_INDICATOR` are 9 px wide and overlap on the sheet; Webamp's
  `#work-indicator` is 3x9, so only the first 3 columns are drawn.
- `MAIN_VOLUME_BACKGROUND`/`MAIN_BALANCE_BACKGROUND` (68x420, 38x420) and `EQ_SLIDER_BACKGROUND` (209x129) are
  frame strips; the composer draws one 68x13/38x13/14x63 frame at an offset.

Bitamp's pressed EQ close button at (0,116) is not adopted: the table keeps Webamp's `EQ_CLOSE_BUTTON` (0,116)
and `EQ_CLOSE_BUTTON_ACTIVE` (0,125), and the generator writes both.

| Sprite | Field | Webamp | sudamp | Why |
|---|---|---|---|---|
