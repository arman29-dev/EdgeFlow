// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EdgeFlow",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "EdgeFlow", targets: ["EdgeFlow"])
    ],
    targets: [
        // Pure, hardware-free logic (settings, gesture state machine, media gate, haptic policy).
        .target(name: "TEGCore"),
        // The macOS app: menu bar, private-framework adapters, CoreAudio, UI.
        .executableTarget(name: "EdgeFlow", dependencies: ["TEGCore"]),
        .testTarget(name: "TEGCoreTests", dependencies: ["TEGCore"]),
    ]
)
