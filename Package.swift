// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GuanDanApp",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "GameCore", targets: ["GameCore"]),
        .library(name: "GameServer", targets: ["GameServer"]),
        .library(name: "GuanDanAppUI", targets: ["GuanDanApp"]),
    ],
    targets: [
        .target(
            name: "GameCore",
            path: "Sources/GameCore"
        ),
        .target(
            name: "GameServer",
            dependencies: ["GameCore"],
            path: "Sources/GameServer"
        ),
        .target(
            name: "GuanDanApp",
            dependencies: ["GameCore", "GameServer"],
            path: "Sources/GuanDanApp"
        ),
    ]
)
