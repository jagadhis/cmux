// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentHome",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentHome",
            targets: ["CmuxAgentHome"]
        ),
    ],
    targets: [
        .target(name: "CmuxAgentHome"),
        .testTarget(
            name: "CmuxAgentHomeTests",
            dependencies: ["CmuxAgentHome"]
        ),
    ]
)
