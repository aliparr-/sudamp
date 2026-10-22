// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// sudamp-dev — headless developer and agent tool (DESIGN §9). Each subcommand lives in Commands/<Name>.swift.
let usage = """
usage: sudamp-dev <command> [options]
  gen-ramp          write the position-ramp test WAV (Fixtures are generated, not committed)
  bench-transport   pull-AO transport benchmark (pause/seek/loadfile latency, CPU)
  stress-lifecycle  create/destroy the engine N times
  devswitch         toggle output devices and check recovery
  engine            yt-dlp engine management (install, status)
  resolve           resolve a stream URL with the isolated yt-dlp
  play-url          play one URL through the engine and report time to first audio
  play              play a genre headless through the full stack (M1)
  ttfa              measure end-to-end time to first audio per source (M1)
  wait              wait until the app's <profile>/debug/state.json matches (M2)
  eq-selftest       measure the 10-band EQ, preamp and balance offline (M3)
  soak              long-running playback with skips; crashes, RSS drift, short reads (M3)
  render            render a skin window state to PNG + RGBA hash (M4)
  skin-load         load a .wsz and report sheets/fallbacks (M4)
  skin-fuzz         mutate skins and check the loader never crashes (M4)
"""

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first, command != "--help", command != "-h" else {
    print(usage)
    exit(argv.isEmpty ? 64 : 0)
}
let args = Args(Array(argv.dropFirst()))

let code: Int32
do {
    switch command {
    case "gen-ramp": code = try await GenRampCommand.run(args)
    case "bench-transport": code = try await BenchTransportCommand.run(args)
    case "stress-lifecycle": code = try await StressLifecycleCommand.run(args)
    case "devswitch": code = try await DevSwitchCommand.run(args)
    case "engine": code = try await EngineCommand.run(args)
    case "resolve": code = try await ResolveCommand.run(args)
    case "play-url": code = try await PlayURLCommand.run(args)
    case "play": code = try await PlayCommand.run(args)
    case "ttfa": code = try await TTFACommand.run(args)
    case "wait": code = try await WaitCommand.run(args)
    case "eq-selftest": code = try await EQSelftestCommand.run(args)
    case "soak": code = try await SoakCommand.run(args)
    case "render": code = try await RenderCommand.run(args)
    case "skin-load": code = try await SkinLoadCommand.run(args)
    case "skin-fuzz": code = try await SkinFuzzCommand.run(args)
    default:
        stderr("unknown command: \(command)\n\(usage)")
        code = 64
    }
} catch {
    stderr("error: \(error)")
    code = 1
}
exit(code)
