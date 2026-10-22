// swift-tools-version:6.2
import PackageDescription

let mpvSrc = "/tmp/sudamp-spike/engine/dl-mpv-src/mpv-0.41"
let package = Package(
    name: "EngineSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "spike",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SudampAO",
            dependencies: [.product(name: "MPVKit", package: "MPVKit")],
            cSettings: [.unsafeFlags(["-I\(mpvSrc)", "-I\(mpvSrc)/audio/out", "-I/tmp/sudamp-spike/engine/pkg/Sources/SudampAO/mpvcfg", "-Wno-everything"])]
        ),
        .executableTarget(
            name: "spikepull",
            dependencies: ["SudampAO", .product(name: "MPVKit", package: "MPVKit")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
