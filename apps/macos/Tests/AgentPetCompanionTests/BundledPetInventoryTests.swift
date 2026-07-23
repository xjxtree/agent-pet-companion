import AgentPetCompanionCore
import CryptoKit
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("Bundled pet inventory")
struct BundledPetInventoryTests {
    @Test
    func swiftPMResourceBundleKeepsTheClosedInventoryDirectory() throws {
        #expect(BundledPetInventory.identifier == "apc.bundled-pets.v1")
        #expect(BundledPetInventory.hasCompleteResources())

        let entries = try FileManager.default.contentsOfDirectory(
            at: BundledPetInventory.directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        #expect(entries.map(\.lastPathComponent).sorted() == BundledPetInventory.fileNames.sorted())

        let expectedDigests = [
            "pet_xingwutuanzi.petpack":
                "9a67254a1ee3f1a2afd599f376fd0cc0ee9935e137426924a99c20a24bdb49c2",
            "pet_bytebudcodex.petpack":
                "a0b64b46054ed5a73abeefc7c0f734cfaa2d92878f5c097ca85bdcb06d547d6f"
        ]
        for entry in entries {
            let data = try Data(contentsOf: entry)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == expectedDigests[entry.lastPathComponent])
        }
    }

    @Test
    func schemaFiveCompatibleMarkerRoundTripsAndUsesBuiltInPresentation() throws {
        let pet = PetSummary(
            id: "pet_xingwutuanzi",
            name: "星雾团子",
            style: "半写实",
            quality: .standard,
            renderSize: RenderSize(width: 192, height: 208),
            petpackPath: "/tmp/pet_xingwutuanzi.petpack",
            coverPath: "/tmp/pet_xingwutuanzi.png",
            origin: .verifiedSkillSource,
            generator: "agent-pet-companion.release-inventory",
            provenance: "apc.bundled-pets.v1",
            active: true,
            createdAt: "2026-07-15T00:00:00Z"
        )

        let decoded = try JSONDecoder().decode(
            PetSummary.self,
            from: JSONEncoder().encode(pet)
        )

        #expect(decoded.origin == .verifiedSkillSource)
        #expect(decoded.isBundled)
        #expect(decoded.generationSourceTitle == "App 内置")
        #expect(decoded.generationSourceDetail == "随 Agent Pet Companion 提供")

        var forgedExternal = decoded
        forgedExternal.origin = .externalImport
        #expect(!forgedExternal.isBundled)
    }

    @Test
    func seedRPCUsesTheBoundedPetpackTimeout() {
        #expect(PetCoreClient.defaultTimeout(for: "petpack.seed_bundled") == .seconds(120))
    }
}
