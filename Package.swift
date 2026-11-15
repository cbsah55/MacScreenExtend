// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacScreenExtend",
    platforms: [.macOS(.v14)],
    targets: [
        // Declarations for Apple's private virtual-display API (lives in CoreGraphics).
        .target(
            name: "CGVirtualDisplayPrivate",
            path: "Sources/CGVirtualDisplayPrivate"
        ),
        // The Mac host: menu bar app that creates virtual displays.
        .executableTarget(
            name: "ScreenExtendHost",
            dependencies: ["CGVirtualDisplayPrivate"],
            path: "Sources/ScreenExtendHost"
        ),
    ]
)
