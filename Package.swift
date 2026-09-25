// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftDrupal",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "drupal", targets: ["SwiftDrupal"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        // All CLI logic: config, commands, output contract, runtime protocol.
        // Containerization is linked here because the real ContainerRuntime
        // will live here; nothing calls it yet.
        .target(
            name: "DrupalKit",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Containerization", package: "containerization"),
            ]
        ),
        // Thin `drupal` entry point; everything testable lives in DrupalKit.
        .executableTarget(
            name: "SwiftDrupal",
            dependencies: ["DrupalKit"]
        ),
        .testTarget(
            name: "DrupalKitTests",
            dependencies: ["DrupalKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
