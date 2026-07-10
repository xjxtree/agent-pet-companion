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
            dependencies: ["AgentPetCompanionCore"]
        ),
        .testTarget(
            name: "AgentPetCompanionTests",
            dependencies: ["AgentPetCompanion", "AgentPetCompanionCore"]
        )
    ]
)
