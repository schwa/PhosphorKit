// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "PhosphorKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "PhosphorModel", targets: ["PhosphorModel"]),
        .library(name: "PhosphorCompile", targets: ["PhosphorCompile"]),
        .library(name: "PhosphorRuntime", targets: ["PhosphorRuntime"])
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0")
    ],
    targets: [
        // Leaf: core data model. No Metal, no external generation deps.
        .target(
            name: "PhosphorModel",
            resources: [
                .copy("Resources/BuiltinTextures"),
                .copy("Resources/StarterTemplate.metal")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        // Parsing, source assembly, and Metal compilation. Owns Phosphor.h.
        .target(
            name: "PhosphorCompile",
            dependencies: [
                "PhosphorModel",
                .product(name: "TOMLKit", package: "TOMLKit")
            ],
            resources: [
                .copy("Resources/Phosphor.h")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        // Live rendering pipeline + audio capture. Raw Metal, no MetalSprockets:
        // PhosphorKit is the standalone embeddable product.
        .target(
            name: "PhosphorRuntime",
            dependencies: [
                "PhosphorModel",
                "PhosphorCompile"
            ],
            resources: [
                .process("Resources/Billboard.metal")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ]
        ),
        .testTarget(
            name: "PhosphorModelTests",
            dependencies: ["PhosphorModel"]
        ),
        .testTarget(
            name: "PhosphorCompileTests",
            dependencies: ["PhosphorModel", "PhosphorCompile"]
        ),
        .testTarget(
            name: "PhosphorRuntimeTests",
            dependencies: ["PhosphorModel", "PhosphorCompile", "PhosphorRuntime"],
            resources: [
                .copy("Resources")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
