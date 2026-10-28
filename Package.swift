// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TypeMouse",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic with no AppKit/AX dependencies, so it is unit-testable.
        .target(name: "TypeMouseCore"),
        .executableTarget(
            name: "TypeMouse",
            dependencies: ["TypeMouseCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(name: "TypeMouseCoreTests", dependencies: ["TypeMouseCore"]),
    ],
    swiftLanguageModes: [.v5]
)
