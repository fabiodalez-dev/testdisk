// swift-tools-version:5.9
// Ritrovo - native macOS front-end for the PhotoRec recovery engine.
// GPL v2 or later, like PhotoRec.
import PackageDescription

let package = Package(
    name: "Ritrovo",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RitrovoCore", path: "Sources/RitrovoCore"),
        .executableTarget(name: "Ritrovo", dependencies: ["RitrovoCore"], path: "Sources/Ritrovo"),
        .executableTarget(name: "RitrovoCoreTests", dependencies: ["RitrovoCore"], path: "Tests/RitrovoCoreTests"),
    ]
)
