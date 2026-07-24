import AgentPetCompanionCore
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
    static let petIDs = [
        "pet_xingwutuanzi",
        "pet_bytebudcodex"
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

    static func validatedSeedResponse(_ value: Any) throws -> BundledPetSeedResponse {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw PetCoreClientError.invalidResponse
        }
        let response: BundledPetSeedResponse
        do {
            response = try JSONDecoder().decode(
                BundledPetSeedResponse.self,
                from: JSONSerialization.data(withJSONObject: value)
            )
        } catch {
            throw PetCoreClientError.invalidResponse
        }
        guard response.inventory == identifier,
              response.outcomes.count == petIDs.count,
              Set(response.outcomes.map(\.petID)) == Set(petIDs),
              Set(response.outcomes.map(\.petID)).count == response.outcomes.count,
              response.outcomes.allSatisfy({ $0.pet.id == $0.petID })
        else {
            throw PetCoreClientError.invalidResponse
        }
        return response
    }
}

struct BundledPetSeedResponse: Decodable, Equatable {
    let inventory: String
    let outcomes: [BundledPetSeedOutcome]
}

struct BundledPetSeedOutcome: Decodable, Equatable {
    enum Status: String, Decodable {
        case installed
        case preservedExistingID = "preserved_existing_id"
    }

    let petID: String
    let status: Status
    let pet: PetSummary

    enum CodingKeys: String, CodingKey {
        case petID = "pet_id"
        case status
        case pet
    }
}
