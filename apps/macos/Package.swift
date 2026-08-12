// swift-tools-version: 6.2

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
        .executable(
            name: "AgentPetCompanionLifecycleClient",
            targets: ["AgentPetCompanionLifecycleClient"]
        )
    ],
    dependencies: [
        // Keep the test framework compatible with the minimum Swift 6.2
        // toolchain while CI and Release build against the macOS 26 SDK.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.1.3")
    ],
    targets: [
        .target(name: "AgentPetCompanionCore"),
        .executableTarget(
            name: "AgentPetCompanion",
            dependencies: ["AgentPetCompanionCore"],
            resources: [
                .process("Resources/AgentPetCompanionMark.png"),
                .process("Resources/PiBadge.svg"),
                // Preserve feature table boundaries and raw catalogs. Runtime
                // uses the tracked `.strings` files for bounded cached lookup.
                .copy("Resources/Localization"),
                // Keep the inventory as one named directory. Processing the
                // parent Resources directory flattens unknown files, which
                // would make the fixed-root PetCore seed contract impossible
                // to verify in a packaged App.
                .copy("Resources/BuiltInPets")
            ]
        ),
        .executableTarget(name: "AgentPetCompanionLifecycleClient"),
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
