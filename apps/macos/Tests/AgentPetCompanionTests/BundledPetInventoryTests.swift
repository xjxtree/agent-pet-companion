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
                "035033377ac607fa07cf26c03100749dad44e8cd0575558d0b4049a1339b3d12",
            "pet_bytebudcodex.petpack":
                "fa1754d815d8aa544e254880183c7ca920098becb32c8e612e4b585d58ed74e0"
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
