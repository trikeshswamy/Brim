// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BrimKit",
    // Brim needs macOS 26 (decided 2026-10-21): it's built on Liquid Glass and tested only on 26+.
    // Keep this the same as the app target's MACOSX_DEPLOYMENT_TARGET.
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BrimCore", targets: ["BrimCore"]),
        .library(name: "BrimSystem", targets: ["BrimSystem"]),
        .library(name: "BrimFeatures", targets: ["BrimFeatures"]),
    ],
    targets: [
        // Pure logic: models, parsers, island rules, service protocols. No UI, nonisolated.
        .target(name: "BrimCore"),
        // Live macOS integrations (helper process, launch at login, system events).
        .target(
            name: "BrimSystem",
            dependencies: ["BrimCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // SwiftUI views and @Observable stores. Must never import BrimSystem.
        .target(
            name: "BrimFeatures",
            dependencies: ["BrimCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "BrimCoreTests", dependencies: ["BrimCore"]),
        // The live services' own logic that needs no network (e.g. your saved lyric fixes).
        .testTarget(
            name: "BrimSystemTests",
            dependencies: ["BrimSystem", "BrimCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "BrimFeaturesTests",
            dependencies: ["BrimFeatures", "BrimCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
