// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PrimeSwitcher",
    platforms: [
        .macOS("14.2"),
    ],
    products: [
        .executable(
            name: "PrimeSwitcher",
            targets: ["Input-to-Output-Monitor"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "Input-to-Output-Monitor",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AudioUnit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "AudioRouterTests",
            dependencies: ["Input-to-Output-Monitor"]
        ),
    ]
)
