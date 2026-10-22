// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1 probe. Usage (from spikes/s1-region):
//   swift run s1probe check                  permission state, without prompting
//   swift run s1probe measure [--png <dir>]  headless WindowServer routing + shadow measurement (JSON)
//   swift run s1probe auto                   real CGEvent clicks; only with Accessibility permission
//   swift run s1probe manual                 interactive probe for the owner's checklist (default)
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "manual" {
case "check":
    printJSON(Permissions.current())
case "measure":
    let pngDir = arguments.firstIndex(of: "--png").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    printJSON(Measure.run(pngDir: pngDir))
case "auto":
    exit(AutoClick.run())
case "manual":
    ManualProbe.run()
default:
    FileHandle.standardError.write(Data("usage: s1probe [check | measure [--png <dir>] | auto | manual]\n".utf8))
    exit(64)
}
