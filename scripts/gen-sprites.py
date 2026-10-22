#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate Sources/SkinKit/Generated/SpriteTable.swift from Webamp's skinSprites.ts (DESIGN §8.2, PLAN M4).

Grown from spikes/skins-tools/extract_sprites.py. Unlike the spike it strips comments with a string-aware
scanner (so the commented-out GENEX block can never leak in), accepts sprite keys in any order, parses
FONT_LOOKUP, refuses duplicate names, applies the overrides documented in docs/spikes/sprite-overrides.md,
and can dump the table as JSON in the spike's format for the equality test.

Usage:
  scripts/gen-sprites.py [--source skinSprites.ts] [--out SpriteTable.swift] [--json out.json] [--check]

--check exits 1 if the generated Swift differs from the file on disk (for CI / make skin-check).
The default source is the pinned Webamp clone in /tmp/sudamp-priorart (git clone --depth 1, commit below).
"""
import argparse
import hashlib
import json
import os
import re
import sys

WEBAMP_COMMIT = "7734cd3c7cf144bab2d8614ce9f9ba2ff21e163e"
DEFAULT_SOURCE = "/tmp/sudamp-priorart/webamp/repo/packages/webamp/js/skinSprites.ts"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(ROOT, "Sources/SkinKit/Generated/SpriteTable.swift")

# Deliberate departures from Webamp's table: name -> {field: value}. Every entry must be justified in
# docs/spikes/sprite-overrides.md. Draw-size differences (e.g. the 22 px next button) live in the layout
# tables instead, so this is empty.
OVERRIDES = {}

# Constants skinSprites.ts imports (packages/webamp/js/constants.ts).
CONSTANTS = {"UTF8_ELLIPSIS": "\u2026"}

MIT_NOTICE = """The MIT License (MIT)

Copyright (c) [2015] [Jordan Eldredge]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""


def strip_comments(src):
    """Remove // and /* */ comments, leaving string literals (", ', `) intact."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                sys.exit("unterminated block comment")
            i = j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def block_after(src, marker):
    """Text between the brace/bracket that follows `marker` and its matching close."""
    start = src.find(marker)
    if start < 0:
        sys.exit(f"marker not found: {marker}")
    open_at = min(p for p in (src.find("{", start + len(marker)), src.find("[", start + len(marker))) if p >= 0)
    pairs = {"{": "}", "[": "]"}
    stack, i = [], open_at
    while i < len(src):
        c = src[i]
        if c in "\"'`":
            j = i + 1
            while src[j] != c:
                j += 2 if src[j] == "\\" else 1
            i = j + 1
            continue
        if c in pairs:
            stack.append(pairs[c])
        elif stack and c == stack[-1]:
            stack.pop()
            if not stack:
                return src[open_at + 1:i]
        i += 1
    sys.exit(f"unbalanced block after {marker}")


def parse_key(token):
    token = token.strip()
    if token.startswith("[") and token.endswith("]"):
        name = token[1:-1].strip()
        if name not in CONSTANTS:
            sys.exit(f"unknown computed key {token}")
        return CONSTANTS[name]
    if token[0] in "\"'":
        return json.loads('"' + token[1:-1].replace('"', '\\"') + '"') if token[0] == "'" else json.loads(token)
    return token


def parse_font_lookup(src):
    # The type annotation `{ [letter: string]: [number, number] }` precedes `=`; skip to the object literal.
    body = block_after(src, "FONT_LOOKUP: { [letter: string]: [number, number] } =")
    entries = []
    pattern = re.compile(r'("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\[[A-Z0-9_]+\]|[^\s:,\[\]]+)\s*:\s*\[\s*(\d+)\s*,\s*(\d+)\s*\]')
    for m in pattern.finditer(body):
        entries.append((parse_key(m.group(1)), int(m.group(2)), int(m.group(3))))
    keys = [k for k, _, _ in entries]
    if len(keys) != len(set(keys)):
        sys.exit("duplicate FONT_LOOKUP keys")
    return entries


def parse_sprites(src):
    body = block_after(src, "const sprites: SpriteMap =")
    sheets = []
    i = 0
    sheet_re = re.compile(r"\s*,?\s*([A-Z_]+)\s*:\s*")
    while i < len(body):
        m = sheet_re.match(body, i)
        if not m:
            if body[i:].strip(" \n\t,") == "":
                break
            sys.exit(f"unexpected text in sprite map: {body[i:i + 60]!r}")
        sheet = m.group(1)
        i = m.end()
        if body.startswith("characterSprites", i):  # TEXT: built from FONT_LOOKUP at runtime
            sheets.append((sheet, None))
            i += len("characterSprites")
            continue
        if body[i] != "[":
            sys.exit(f"sheet {sheet} is not an array literal")
        depth, j = 0, i
        while True:
            if body[j] == "[":
                depth += 1
            elif body[j] == "]":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        items = []
        for obj in re.finditer(r"\{([^{}]*)\}", body[i + 1:j]):
            fields = dict(re.findall(r"(\w+)\s*:\s*(\"[^\"]*\"|\d+)", obj.group(1)))
            try:
                items.append(dict(name=json.loads(fields["name"]), x=int(fields["x"]), y=int(fields["y"]),
                                  w=int(fields["width"]), h=int(fields["height"])))
            except KeyError as e:
                sys.exit(f"sprite in {sheet} lacks {e}: {obj.group(0)}")
        sheets.append((sheet, items))
        i = j + 1
    return sheets


def camel(name):
    parts = name.lower().split("_")
    return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])


def swift_char(c):
    if c == "\\":
        return '"\\\\"'
    if c == '"':
        return '"\\""'
    if ord(c) > 0x7E:
        return '"\\u{%04X}"' % ord(c)
    return '"%s"' % c


def generate(source_path):
    raw = open(source_path, encoding="utf-8").read()
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
    src = strip_comments(raw)
    font = parse_font_lookup(src)
    sheets = parse_sprites(src)

    sprites = []
    for sheet, items in sheets:
        for item in items or []:
            item = dict(item, sheet=sheet, **OVERRIDES.get(item["name"], {}))
            sprites.append(item)
    names = [s["name"] for s in sprites]
    if len(names) != len(set(names)):
        sys.exit("duplicate sprite names")
    unknown = set(OVERRIDES) - set(names)
    if unknown:
        sys.exit(f"overrides for unknown sprites: {sorted(unknown)}")

    sheet_names = [s for s, _ in sheets]
    lines = [
        "// SPDX-License-Identifier: GPL-3.0-or-later",
        "// GENERATED by scripts/gen-sprites.py; do not edit by hand. Regenerate after changing the script or the pin.",
        f"// Source: captbaritone/webamp packages/webamp/js/skinSprites.ts @ {WEBAMP_COMMIT}",
        f"// Source SHA-256: {digest}",
        f"// {len(sprites)} sprites on {len(sheet_names)} sheets, {len(font)} FONT_LOOKUP entries;"
        f" overrides: {len(OVERRIDES)} (docs/spikes/sprite-overrides.md).",
        "//",
        "// Sprite names, coordinates and the text.bmp character map are Webamp's (MIT); its notice:",
        "//",
    ]
    lines += [("// " + l).rstrip() for l in MIT_NOTICE.splitlines()]
    lines += [
        "",
        "/// The bitmaps of a classic skin that carry sprites (Webamp's sheet names).",
        "public enum SpriteSheet: String, CaseIterable, Sendable, Codable {",
    ]
    lines += [f'    case {camel(s)} = "{s}"' for s in sheet_names]
    lines += [
        "",
        '    /// Lower-case file name without extension, e.g. "nums_ex" for nums_ex.bmp.',
        "    public var fileBase: String { rawValue.lowercased() }",
        "}",
        "",
        "/// Where a sprite lives: its sheet and its rect in sheet pixels (top-left origin).",
        "public struct SpriteSource: Hashable, Sendable {",
        "    public let sheet: SpriteSheet",
        "    public let rect: IntRect",
        "",
        "    public init(_ sheet: SpriteSheet, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {",
        "        self.sheet = sheet",
        "        self.rect = IntRect(x, y, width, height)",
        "    }",
        "}",
        "",
        "/// Every sprite in Webamp's table except the text.bmp characters (see `FontLookup`).",
        "public enum Sprite: String, CaseIterable, Sendable, Codable {",
    ]
    lines += [f'    case {camel(s["name"])} = "{s["name"]}"' for s in sprites]
    lines += [
        "",
        "    public var source: SpriteSource {",
        "        switch self {",
    ]
    lines += [f'        case .{camel(s["name"])}: return SpriteSource(.{camel(s["sheet"])}, {s["x"]}, {s["y"]}, {s["w"]}, {s["h"]})'
              for s in sprites]
    lines += [
        "        }",
        "    }",
        "}",
        "",
        "/// One 5x6 glyph cell in text.bmp.",
        "public struct TextCell: Hashable, Sendable {",
        "    public let row: Int",
        "    public let column: Int",
        "",
        "    public init(_ row: Int, _ column: Int) {",
        "        self.row = row",
        "        self.column = column",
        "    }",
        "}",
        "",
        "/// Webamp's FONT_LOOKUP: lower-cased characters to text.bmp cells (`<>{}` share the `[]` glyphs).",
        "public enum FontLookup {",
        "    public static let cellWidth = 5",
        "    public static let cellHeight = 6",
        "    public static let cells: [Character: TextCell] = [",
    ]
    lines += [f"        {swift_char(k)}: TextCell({r}, {c})," for k, r, c in font]
    lines += ["    ]", "}", ""]
    as_json = {s["name"]: dict(sheet=s["sheet"], x=s["x"], y=s["y"], w=s["w"], h=s["h"]) for s in sprites}
    return "\n".join(lines), as_json


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=DEFAULT_SOURCE)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--json")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    swift, as_json = generate(args.source)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(as_json, f, indent=0, sort_keys=True)
    if args.check:
        current = open(args.out, encoding="utf-8").read() if os.path.exists(args.out) else ""
        if current != swift:
            print(f"{args.out} is out of date; run scripts/gen-sprites.py", file=sys.stderr)
            sys.exit(1)
        print(f"{args.out} is up to date ({len(as_json)} sprites)")
        return
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(swift)
    print(f"wrote {args.out}: {len(as_json)} sprites")


if __name__ == "__main__":
    main()
