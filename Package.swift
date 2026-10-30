// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SingleFlight",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
    products: [
        .library(name: "SingleFlight", targets: ["SingleFlight"]),
    ],
    targets: [
        .target(
            name: "SingleFlight",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "SingleFlightTests", dependencies: ["SingleFlight"]),
    ]
)
