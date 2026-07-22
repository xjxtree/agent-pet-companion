import Foundation

/// The signed App resource inventory that PetCore may install with bundled
/// origin. PetCore independently pins both package IDs and SHA-256 digests;
/// this type only resolves the SwiftPM resource directory and never accepts a
/// caller-selected package path.
enum BundledPetInventory {
    static let identifier = "apc.bundled-pets.v1"
    static let resourceDirectoryName = "BuiltInPets"
    static let fileNames = [
        "pet_xingwutuanzi.petpack",
        "pet_bytebudcodex.petpack"
    ]

    static var directoryURL: URL {
        APCResourceBundle.resourceURL(resourceDirectoryName)
    }

    static func hasCompleteResources(fileManager: FileManager = .default) -> Bool {
        fileNames.allSatisfy { fileName in
            fileManager.isReadableFile(
                atPath: directoryURL.appendingPathComponent(fileName).path
            )
        }
    }

    static var rpcParameters: [String: String] {
        [
            "inventory": identifier,
            "inventory_root": directoryURL.standardizedFileURL.path
        ]
    }
}
