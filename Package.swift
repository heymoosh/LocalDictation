// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalDictation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LocalDictation", targets: ["LocalDictationApp"]),
        .library(name: "LocalDictationCore", targets: ["LocalDictationCore"]),
        .executable(name: "LocalDictationCoreChecks", targets: ["LocalDictationCoreChecks"]),
    ],
    targets: [
        .target(name: "LocalDictationCore"),
        .executableTarget(name: "LocalDictationApp", dependencies: ["LocalDictationCore"]),
        .executableTarget(name: "LocalDictationCoreChecks", dependencies: ["LocalDictationCore"]),
        .testTarget(name: "LocalDictationCoreTests", dependencies: ["LocalDictationCore"]),
    ]
)
