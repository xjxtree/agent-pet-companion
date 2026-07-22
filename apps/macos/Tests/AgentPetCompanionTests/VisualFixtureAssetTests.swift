import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("UI Next deterministic pet assets")
struct VisualFixtureAssetTests {
    @Test
    func checkedInBytebudFixtureProvidesAReadableCoverAndEveryProtocolState() throws {
        let pet = OverlayCoreFixturePet.bytebud

        let coverURL = try #require(PetAssetLocator.coverURL(for: pet))
        #expect(FileManager.default.isReadableFile(atPath: coverURL.path))

        for state in ["idle", "start", "tool", "waiting", "review", "done", "failed"] {
            let frames = PetAssetLocator.frameURLs(for: pet, stateName: state)
            #expect(frames.count == 1)
            #expect(frames.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) })
        }
    }
}
