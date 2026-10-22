# Webamp parser fixtures

Copied unmodified from [captbaritone/webamp](https://github.com/captbaritone/webamp) at commit
`7734cd3c7cf144bab2d8614ce9f9ba2ff21e163e`:

- `packages/webamp/js/__tests__/fixtures/*`: 7 region, 4 viscolor (VISCOLOR.TXT, CENTRA_VISCOLOR.TXT,
  viscolor_valgaav.txt, viscolor_green_dimension.txt) and 4 pledit (PLEDIT*.TXT) files;
- `packages/webamp/js/__snapshots__/regionParser.test.js.snap`: Webamp's expected region parser output.

`Tests/SkinKitTests/ParserTests.swift` runs SkinKit's parsers against them and compares with the snapshot and
with the expectations in Webamp's `utils.test.ts`.

These files are under Webamp's MIT licence (`LICENSE.txt`, © 2015 Jordan Eldredge). Some fixtures are text files
from third-party skins (named in Webamp's tests); they contain only colour values and polygon coordinates.
