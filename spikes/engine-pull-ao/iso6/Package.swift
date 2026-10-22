// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "iso6", platforms: [.macOS(.v15)],
  targets: [.executableTarget(name: "iso6", swiftSettings: [.swiftLanguageMode(.v6)])])
