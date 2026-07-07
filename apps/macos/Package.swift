// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentPetCompanion",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AgentPetCompanionCore", targets: ["AgentPetCompanionCore"]),
        .executable(name: "AgentPetCompanion", targets: ["AgentPetCompanion"]),
        .executable(name: "AgentPetCompanionCoreValidation", targets: ["AgentPetCompanionCoreValidation"])
    ],
    targets: [
        .target(name: "AgentPetCompanionCore"),
        .executableTarget(
            name: "AgentPetCompanion",
            dependencies: ["AgentPetCompanionCore"]
        ),
        .executableTarget(
            name: "AgentPetCompanionCoreValidation",
            dependencies: ["AgentPetCompanionCore"]
        )
    ]
)
