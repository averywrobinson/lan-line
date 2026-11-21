// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LanLine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LanLineCore", targets: ["LanLineCore"]),
        .executable(name: "LanLine", targets: ["LanLine"]),
    ],
    targets: [
        .target(name: "LanLineCore"),
        .executableTarget(name: "LanLine", dependencies: ["LanLineCore"]),
        .testTarget(name: "LanLineCoreTests", dependencies: ["LanLineCore"]),
    ]
)
