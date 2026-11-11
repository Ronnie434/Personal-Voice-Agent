// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Friday",
    platforms: [.macOS(.v14)],
    targets: [
        // No UI: protocol, socket, engine supervisor, settings, keychain.
        .target(name: "FridayCore"),
        // Everything visible: tokens, the five surfaces, and the engine model they read.
        .target(name: "FridayUI", dependencies: ["FridayCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "Friday", dependencies: ["FridayUI", "FridayCore"]),
        .testTarget(name: "FridayCoreTests", dependencies: ["FridayCore"]),
    ]
)
