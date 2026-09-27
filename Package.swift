// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lyra",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LyraCore", targets: ["LyraCore"]),
        .library(name: "LyraGaze", targets: ["LyraGaze"]),
        .library(name: "LyraSpeech", targets: ["LyraSpeech"]),
        .library(name: "LyraInput", targets: ["LyraInput"]),
        .library(name: "LyraAccessibility", targets: ["LyraAccessibility"]),
        .executable(name: "LyraApp", targets: ["LyraApp"])
    ],
    targets: [
        // Pure domain logic. No OS frameworks, no hardware, no UI. Everything that can be
        // tested without a camera or a permission grant lives here.
        .target(
            name: "LyraCore",
            dependencies: []
        ),
        // Camera capture and facial measurement. Emits raw features, never screen points.
        .target(
            name: "LyraGaze",
            dependencies: ["LyraCore"]
        ),
        // Speech recognition and transcript delivery.
        .target(
            name: "LyraSpeech",
            dependencies: ["LyraCore"]
        ),
        // CoreGraphics event generation, the coordinate fallback.
        .target(
            name: "LyraInput",
            dependencies: ["LyraCore"]
        ),
        // macOS accessibility tree access, the preferred semantic layer.
        .target(
            name: "LyraAccessibility",
            dependencies: ["LyraCore"]
        ),
        .executableTarget(
            name: "LyraApp",
            dependencies: [
                "LyraCore",
                "LyraGaze",
                "LyraSpeech",
                "LyraInput",
                "LyraAccessibility"
            ]
        ),
        .testTarget(
            name: "LyraCoreTests",
            dependencies: [
                "LyraCore",
                "LyraGaze"
            ]
        )
    ]
)
