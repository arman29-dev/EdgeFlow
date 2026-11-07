// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackpadEdgeGestures",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "TrackpadEdgeGestures", targets: ["TrackpadEdgeGestures"])
    ],
    targets: [
        // Pure, hardware-free logic (settings, gesture state machine, media gate, haptic policy).
        .target(name: "TEGCore"),
        // The macOS app: menu bar, private-framework adapters, CoreAudio, UI.
        .executableTarget(name: "TrackpadEdgeGestures", dependencies: ["TEGCore"]),
        .testTarget(name: "TEGCoreTests", dependencies: ["TEGCore"]),
    ]
)
