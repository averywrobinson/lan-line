// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LanLine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FerryCore", targets: ["FerryCore"]),
        .executable(name: "LanLine", targets: ["LanLine"]),
    ],
    targets: [
        .target(name: "FerryCore"),
        .executableTarget(name: "LanLine", dependencies: ["FerryCore"]),
        .testTarget(name: "FerryCoreTests", dependencies: ["FerryCore"]),
    ]
)
