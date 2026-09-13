// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftDrupal",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "drupal", targets: ["DrupalCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.0.0"),
    ],
    targets: [
        // All testable logic (config model, CLI commands, output/exit-code
        // contract) lives in the `SwiftDrupal` library target so the test
        // target and later sorties can import it without relying on
        // executable-target test linking.
        .target(
            name: "SwiftDrupal",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        // Thin entry point that produces the `drupal` binary.
        .executableTarget(
            name: "DrupalCLI",
            dependencies: ["SwiftDrupal"]
        ),
        .testTarget(
            name: "SwiftDrupalTests",
            dependencies: [
                "SwiftDrupal",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
