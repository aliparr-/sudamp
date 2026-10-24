// swift-tools-version: 6.3
// sudamp — The Sudden Amp. GPL-3.0-or-later (SudampAO: LGPL-2.1-or-later). See docs/DESIGN.md §4 and §9.
import PackageDescription

/// UI targets default to the main actor (DESIGN §5.5). Everything else is nonisolated by default.
let mainActorByDefault: [SwiftSetting] = [.defaultIsolation(MainActor.self)]

let mpvKit: Target.Dependency = .product(name: "MPVKit", package: "MPVKit")

/// Linker map so `make verify-binary` can prove `_audio_out_pcm` comes from sudamp_ao.o (DESIGN §5.3). Only
/// `make build` asks for it (SUDAMP_LINK_MAP=1): other scratch-path builds must not overwrite the shared map.
let linkMap: [LinkerSetting] = Context.environment["SUDAMP_LINK_MAP"] == "1"
    ? [.unsafeFlags(["-Xlinker", "-map", "-Xlinker", Context.packageDirectory + "/.build/sudamp-link.map"])]
    : []

let package = Package(
    name: "sudamp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sudamp", targets: ["sudamp"]),
        .executable(name: "sudamp-dev", targets: ["sudamp-dev"]),
        .executable(name: "skingen", targets: ["skingen"]),
        .executable(name: "catalog-tool", targets: ["catalog-tool"]),
    ],
    dependencies: [
        // Exact pin: SudampAO overrides an mpv-internal symbol and is compiled against v0.41.0 headers (DESIGN §5.1).
        // 1.1.0-n9.0.2 is a pre-release; 1.0.0 = mpv v0.41.0 + FFmpeg n8.1.2, static libmpv.
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0"),
    ],
    targets: [
        // MARK: Pure / nonisolated libraries
        .target(name: "Core"),
        .target(name: "Catalog", dependencies: ["Core"]),
        .target(name: "Picker", dependencies: ["Core", "Catalog"]),
        .target(name: "Feeds", dependencies: ["Core", "Catalog"]),
        .target(name: "Resolver", dependencies: ["Core", "Catalog"]),
        .target(name: "SkinKit", dependencies: ["Core"]),

        // MARK: Engine
        // LGPL-2.1-or-later: defines mpv's `audio_out_pcm` as a pull AO (link-time override). Vendored mpv
        // v0.41.0 internal headers live in vendor/ (scripts/vendor-mpv-headers.sh, scripts/gen-mpv-config.sh).
        .target(
            name: "SudampAO",
            dependencies: [mpvKit],
            exclude: ["vendor/LICENSE.LGPL", "vendor/README.md"],
            cSettings: [
                .headerSearchPath("vendor/mpv"),
                .headerSearchPath("vendor/mpv/audio/out"),
                .headerSearchPath("vendor/config"),
            ]
        ),
        // ObjC/C real-time render bridge (no Swift on the IO thread, DESIGN §5.2).
        .target(
            name: "AudioRender",
            dependencies: ["SudampAO"],
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox")]
        ),
        .target(name: "MPV", dependencies: ["Core", "SudampAO", mpvKit]),
        .target(
            name: "Audio",
            dependencies: ["Core", "AudioRender"],
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("Accelerate")]
        ),

        // MARK: Playback (main actor by default): PlaybackController executes SessionMachine effects over the
        // feed, picker, resolver, mpv and audio engine. Shared by the app (Shell) and sudamp-dev (headless).
        .target(
            name: "Playback",
            dependencies: ["Core", "Catalog", "Picker", "Feeds", "Resolver", "MPV", "Audio"],
            swiftSettings: mainActorByDefault
        ),

        // MARK: UI (main actor by default)
        .target(name: "SkinUI", dependencies: ["Core", "SkinKit"], swiftSettings: mainActorByDefault),
        // The modern skin class (DESIGN §8.4): native AppKit, Core Animation and Liquid Glass, no .wsz.
        .target(name: "ModernUI", swiftSettings: mainActorByDefault),
        .target(
            name: "Shell",
            dependencies: ["Core", "Catalog", "Picker", "Feeds", "Resolver", "MPV", "Audio", "Playback", "SkinKit", "SkinUI",
                           "ModernUI"],
            resources: [.process("Resources")],
            swiftSettings: mainActorByDefault
        ),

        // MARK: Executables
        .executableTarget(
            name: "sudamp",
            dependencies: ["Shell"],
            swiftSettings: mainActorByDefault,
            linkerSettings: linkMap
        ),
        .executableTarget(
            name: "sudamp-dev",
            dependencies: ["Core", "Catalog", "Picker", "Feeds", "Resolver", "MPV", "Audio", "Playback", "SkinKit"]
        ),
        .executableTarget(name: "skingen", dependencies: ["Core", "SkinKit"]),
        .executableTarget(name: "catalog-tool", dependencies: ["Core", "Catalog", "Feeds", "Resolver"]),

        // MARK: Tests (Swift Testing only; library targets only)
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog"]),
        .testTarget(name: "PickerTests", dependencies: ["Picker"]),
        .testTarget(name: "FeedsTests", dependencies: ["Feeds"]),
        .testTarget(name: "ResolverTests", dependencies: ["Resolver"]),
        .testTarget(name: "MPVTests", dependencies: ["MPV", "SudampAO"]),
        .testTarget(name: "AudioTests", dependencies: ["Audio"]),
        .testTarget(name: "SkinKitTests", dependencies: ["SkinKit"]),
        .testTarget(name: "PlaybackTests", dependencies: ["Playback"]),
        .testTarget(name: "SkinUITests", dependencies: ["SkinUI", "SkinKit"]),
        .testTarget(name: "ModernUITests", dependencies: ["ModernUI"]),
        .testTarget(name: "ShellTests", dependencies: ["Shell"]),
    ]
)
