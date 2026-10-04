// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hefty",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BigFileCore", targets: ["BigFileCore"]),
        .executable(name: "Hefty", targets: ["Hefty"]),
    ],
    targets: [
        // Pure engine: no AppKit, unit-testable, reusable by a future CLI.
        .target(name: "BigFileCore", linkerSettings: [.linkedLibrary("iconv")]),
        // The macOS app (AppKit + CoreText). Depends only on the engine.
        .executableTarget(name: "Hefty", dependencies: ["BigFileCore"]),
        .testTarget(name: "BigFileCoreTests", dependencies: ["BigFileCore"]),
    ]
)
