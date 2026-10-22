// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S1 (docs/PLAN.md M0): a non-anti-aliased region.txt rasteriser plus an AppKit probe for
// click-through and shadow behaviour of shaped windows. Standalone and throwaway: not part of the app build.
import PackageDescription

let package = Package(
    name: "s1-region",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure: no AppKit, no Foundation. M4 moves the rasteriser into SkinKit.
        .target(name: "RegionRaster"),
        .executableTarget(
            name: "s1probe",
            dependencies: ["RegionRaster"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "RegionRasterTests", dependencies: ["RegionRaster"]),
    ]
)
