// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LanLine",
    platforms: [.macOS(.v13), .iOS(.v17)],   // iOS: the iPhone companion (beta.10) uses LanLineCore
    products: [
        .library(name: "LanLineCore", targets: ["LanLineCore"]),
        .executable(name: "LanLine", targets: ["LanLine"]),
    ],
    targets: [
        .target(name: "LanLineCore"),
        .executableTarget(name: "LanLine", dependencies: ["LanLineCore"]),
        .testTarget(name: "LanLineCoreTests", dependencies: ["LanLineCore"], exclude: ["Fixtures"]),
    ]
)
