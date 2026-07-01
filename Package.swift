// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "KCDeepL",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KCDeepL", targets: ["KCDeepL"]),
        .library(name: "KCDeepLCore", targets: ["KCDeepLCore"])
    ],
    targets: [
        .target(name: "KCDeepLCore"),
        .executableTarget(
            name: "KCDeepL",
            dependencies: ["KCDeepLCore"],
            path: "Sources/App",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "KCDeepLCoreTests",
            dependencies: ["KCDeepLCore"]
        )
    ]
)
