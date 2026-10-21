// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeamsPulse",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TeamsPulse", targets: ["TeamsPulse"]),
    ],
    targets: [
        .target(
            name: "PulseCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "TeamsPulse",
            dependencies: ["PulseCore"],
            // Summaries use Apple's on-device model (macOS 26 and later); linked weakly so the app
            // still opens on macOS 15, where the framework doesn't exist.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])]
        ),
        .testTarget(
            name: "PulseCoreTests",
            dependencies: ["PulseCore"]
        ),
    ]
)
