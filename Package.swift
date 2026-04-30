// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "lightpaper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "lightpaper-scan", targets: ["LightpaperScan"]),
        .executable(name: "lightpaper-view", targets: ["LightpaperView"])
    ],
    targets: [
        .executableTarget(
            name: "LightpaperScan",
            path: "Sources/LightpaperScan"
        ),
        .executableTarget(
            name: "LightpaperView",
            path: "Sources/LightpaperView"
        )
    ]
)
