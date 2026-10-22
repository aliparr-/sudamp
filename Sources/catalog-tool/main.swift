// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// catalog-tool: build, lint, sign, verify, probe and discover the feed (PLAN M7, DESIGN §7; docs/catalog.md).

let started = ContinuousClock.now
let usage = """
usage: catalog-tool <command> [options]
  build    [<catalog-dir>] [--check] [--offline] [--force]     sources → catalog/feed.json (deterministic)
  lint     [<catalog-dir>|<feed.json>] [--json] [--dns]          schema, canonical refs, duplicates, coverage, engine
  sign     --key <file|-> [<feed.json>]                          Ed25519 → <feed.json>.sig (64 raw bytes)
  verify   (--pub <file>|--embedded|--production) [<feed.json>]  check <feed.json>.sig
  keygen   --out <prefix>                                        new keypair (<prefix>.key 0600, <prefix>.pub)
  probe    [<catalog-dir>|<feed.json>] --profile <dir> [...]     resolve + range GET each item (YouTube rationed)
  discover --genre <tag> [...]                                   radio-browser, scsearch, Mixcloud candidates
  fetch    --profile <dir> [--url <u>] [--budget 5] [--choose]   the app's launch feed refresh, headless
  bump     [<catalog-dir>] [--expires-days 182]                  revision + 1, new generatedAt/expiresAt
  split    <feed.json> --out <catalog-dir>                       one-time: feed.json → source files
Run a command without arguments for its options.
"""

let args = ToolArgs(CommandLine.arguments.dropFirst())
let code: Int32
switch args.command {
case "build": code = await BuildCommands.build(args)
case "lint": code = await BuildCommands.lint(args)
case "split": code = BuildCommands.split(args)
case "bump": code = BuildCommands.bump(args)
case "keygen": code = SignCommands.keygen(args)
case "sign": code = SignCommands.sign(args)
case "verify": code = SignCommands.verify(args)
case "probe": code = await ProbeCommand.run(args)
case "discover": code = await DiscoverCommand.run(args)
case "fetch": code = await FetchCommand.run(args, started: started)
case "help", "--help", "-h", nil:
    print(usage)
    code = args.command == nil ? 64 : 0
default:
    stderr("catalog-tool: unknown command \(args.command ?? "")\n\(usage)")
    code = 64
}
exit(code)
