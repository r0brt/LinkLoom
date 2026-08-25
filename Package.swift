// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LinkLoom",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LinkLoomCore", targets: ["LinkLoomCore"]),
        .library(name: "LinkLoomAppFeature", targets: ["LinkLoomAppFeature"]),
        .executable(name: "LinkLoomApp", targets: ["LinkLoomApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.10.0"),
    ],
    targets: [
        .target(
            name: "LinkLoomCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "LinkLoomAppFeature", dependencies: ["LinkLoomCore"]),
        .executableTarget(
            name: "LinkLoomApp",
            dependencies: ["LinkLoomCore", "LinkLoomAppFeature"]
        ),
        .testTarget(
            name: "LinkLoomCoreTests",
            dependencies: ["LinkLoomCore"],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "LinkLoomAppFeatureTests",
            dependencies: ["LinkLoomAppFeature", "LinkLoomCore"]
        ),
    ]
)
