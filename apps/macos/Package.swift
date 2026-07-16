// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentPetCompanion",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentPetCompanionCore", targets: ["AgentPetCompanionCore"]),
        .executable(name: "AgentPetCompanion", targets: ["AgentPetCompanion"]),
        .executable(name: "AgentPetCompanionCoreValidation", targets: ["AgentPetCompanionCoreValidation"]),
        .executable(
            name: "AgentPetCompanionTransportValidation",
            targets: ["AgentPetCompanionTransportValidation"]
        ),
        .executable(
            name: "AgentPetCompanionUIValidation",
            targets: ["AgentPetCompanionUIValidation"]
        )
    ],
    dependencies: [
        // Keep the test framework compatible with the Swift 6.1 toolchain on
        // the macOS 15 CI runner. Newer 6.2/6.3 tags raise their own manifest
        // tools version and cannot even be resolved by that baseline.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.1.3")
    ],
    targets: [
        .target(name: "AgentPetCompanionCore"),
        .executableTarget(
            name: "AgentPetCompanion",
            dependencies: ["AgentPetCompanionCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AgentPetCompanionCoreValidation",
            dependencies: ["AgentPetCompanionCore"]
        ),
        .executableTarget(
            name: "AgentPetCompanionTransportValidation",
            dependencies: ["AgentPetCompanionCore"]
        ),
        .executableTarget(
            name: "AgentPetCompanionUIValidation",
            dependencies: ["AgentPetCompanion", "AgentPetCompanionCore"]
        ),
        .testTarget(
            name: "AgentPetCompanionCoreTests",
            dependencies: [
                "AgentPetCompanionCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "AgentPetCompanionTests",
            dependencies: [
                "AgentPetCompanion",
                "AgentPetCompanionCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ]
)
