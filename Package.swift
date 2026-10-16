// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSpeed",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexSpeed", targets: ["CodexSpeed"])],
    targets: [
        .target(name: "SpeedCore", resources: [.process("Resources")]),
        .executableTarget(name: "CodexSpeed", dependencies: ["SpeedCore"]),
        .testTarget(name: "SpeedCoreTests", dependencies: ["SpeedCore"])
    ]
)
