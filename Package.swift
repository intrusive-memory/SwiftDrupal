// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftDrupal",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "drupal", targets: ["SwiftDrupal"]),
        // Runtime spike (docs/spikes/01-containerization-runtime-spike.md); not shipped.
        .executable(name: "container-spike", targets: ["ContainerSpike"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization", from: "0.1.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "SwiftDrupal",
            dependencies: [
                .product(name: "Containerization", package: "containerization")
            ]
        ),
        .executableTarget(
            name: "ContainerSpike",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ]
        ),
        .testTarget(
            name: "SwiftDrupalTests",
            dependencies: ["SwiftDrupal"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
