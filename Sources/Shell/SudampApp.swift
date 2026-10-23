// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Core
import MPV

/// Entry point used by the `sudamp` executable.
///
/// - `--selftest` (with `--engine-check`), `--skin-preview`: terminal checks and the skin preview (M0, M4).
/// - `--snapshot <dir> --states <json>…`: renders app states offscreen and exits (PLAN M5 goldens).
/// - otherwise the app: the skinned windows by default (PLAN M5), M2's plain window with `--plain`. The profile's
///   instance lock is taken before anything else starts; when another sudamp holds it, this launch forwards its
///   arguments (skin paths made absolute) and `sudamp:` URLs over `<profile>/instance.sock` and exits 0 (DESIGN §4).
///   `--automation` runs a script and exits (it never forwards: a busy profile exits 75).
public enum SudampApp {
    public static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest"), args.contains("--engine-check") {
            let report = EngineSelfTest.run(arguments: args)
            print(EngineSelfTest.json(report, pretty: !args.contains("--json")))
            exit(report.ok ? 0 : 1)
        }
        if args.contains("--skin-preview") {
            SkinPreview.run(arguments: args)
            return
        }
        if args.contains("--modern-preview") {
            ModernPreview.run(arguments: args)
            return
        }
        if args.contains("--selftest") {
            let report = SelfTest.run(arguments: args)
            print(report.json(pretty: !args.contains("--json")))
            exit(report.ok ? 0 : 1)
        }

        let shell: ShellArguments
        let launch: LaunchArguments
        do {
            shell = try ShellArguments.parse(Array(args.dropFirst()))
            launch = try LaunchArguments.parse(shell.remaining)
        } catch {
            stderr("sudamp: \(error)\n\(LaunchArgumentsError.usage)\n\(usage)")
            exit(64)
        }
        if let directory = shell.snapshotDirectory {
            guard !shell.states.isEmpty else {
                stderr("sudamp: --snapshot needs --states <state.json> …")
                exit(64)
            }
            exit(AppSnapshot.run(directory: directory, states: shell.states))
        }
        for unknown in launch.unknown { stderr("sudamp: ignoring unknown argument \(unknown)") }
        var script: ShellAutomationScript?
        if let path = launch.automation {
            do {
                script = try ShellAutomationScript.load(from: URL(filePath: (path as NSString).expandingTildeInPath))
                script?.appendSkips(launch.skips, dwell: launch.skipDwell ?? AutomationScript.defaultSkipDwell)
            } catch {
                stderr("sudamp: \(path): \(error)")
                exit(64)
            }
        }

        let paths = Paths.resolve(arguments: args)
        let lock: InstanceLock
        do {
            lock = try InstanceLock.acquire(paths: paths)
        } catch .inUse(let path, let holder) {
            if script != nil {
                stderr("sudamp: profile in use (\(path) is locked by pid \(holder.map(String.init) ?? "?"))")
                exit(75)
            }
            exit(forward(launch: launch, arguments: ShellArguments.forwardedArguments(Array(args.dropFirst())), paths: paths))
        } catch {
            stderr("sudamp: \(error)")
            exit(73)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate(launch: launch, shellArguments: shell, paths: paths, lock: lock, script: script)
        app.delegate = delegate
        // Automation runs without a Dock icon or menu-bar takeover, and never takes focus from the owner.
        app.setActivationPolicy(script == nil ? .regular : .accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    /// The second launch: hand our URLs and arguments to the running instance (DESIGN §4). 0 when delivered.
    static func forward(launch: LaunchArguments, arguments: [String], paths: Paths) -> Int32 {
        let message = InstanceMessage(arguments: arguments, urls: launch.urls)
        do {
            try InstanceClient.send(message, to: paths.instanceSocket, timeout: 3)
            return 0
        } catch {
            let holder = (try? String(contentsOf: paths.instanceLock, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            stderr("sudamp: profile in use (pid \(holder)) and it did not answer on \(paths.instanceSocket.path): \(error)")
            return 75
        }
    }

    static let usage = """
      skinned player: sudamp [<skin.wsz>] [--scale 1|1.2|1.5|2|2.5|3] [--no-region] [--ignore-occlusion] (default; --plain for M2's window)
      snapshots:      sudamp --snapshot <dir> --states <state.json> …
    """

    static func stderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
