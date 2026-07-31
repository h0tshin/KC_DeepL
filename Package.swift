// swift-tools-version: 5.9

import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
// A local Finder duplicate is not product source, but SwiftPM otherwise compiles it.
let localReadingFontBackup = packageRoot
    .appendingPathComponent("Sources/KCDeepLCore/ReadingFontSize 2.swift")
let coreExcludes = FileManager.default.fileExists(atPath: localReadingFontBackup.path)
    ? ["ReadingFontSize 2.swift"]
    : []

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
        .target(
            name: "KCDeepLCore",
            exclude: coreExcludes
        ),
        .executableTarget(
            name: "KCDeepL",
            dependencies: ["KCDeepLCore"],
            path: "Sources/App",
            exclude: [
                "KCDeepL.entitlements"
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "KCDeepLCoreTests",
            dependencies: ["KCDeepLCore"]
        ),
        .testTarget(
            name: "KCDeepLAppTests",
            dependencies: ["KCDeepL"]
        )
    ]
)
