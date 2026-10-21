// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeamsPulse",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TeamsPulse", targets: ["TeamsPulse"]),
    ],
    dependencies: [
        // In-app updates. Only the app target uses it; PulseCore and its tests don't.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "PulseCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "TeamsPulse",
            dependencies: [
                "PulseCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // scripts/build-app.sh embeds Sparkle.framework in the app's Contents/Frameworks.
            // FoundationModels (summaries, macOS 26) is newer than the deployment target, so the
            // linker links it weakly by itself, and the app still opens on macOS 15.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "PulseCoreTests",
            dependencies: ["PulseCore"]
        ),
    ]
)
