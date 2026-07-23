import Foundation
import Testing
@testable import AgentPetCompanion

@Suite
struct PetAssetLocatorTests {
    @Test
    func frameNamesUseTheSameDeterministicASCIIOrderAsPetCore() {
        let names = [
            "frame-10.png",
            "frame-02.png",
            "frame-2.png",
            "frame-1.png",
            "frame-002.png",
            "Frame-2.png",
        ]

        let ordered = names.sorted {
            PetAssetLocator.naturalFrameNameCompare($0, $1) == .orderedAscending
        }

        #expect(ordered == [
            "Frame-2.png",
            "frame-1.png",
            "frame-2.png",
            "frame-02.png",
            "frame-002.png",
            "frame-10.png",
        ])
    }

    @Test
    func frameNameOrderingIsByteStableForCaseAndNumericTies() {
        #expect(
            PetAssetLocator.naturalFrameNameCompare("Frame2.png", "frame2.png")
                == .orderedAscending
        )
        #expect(
            PetAssetLocator.naturalFrameNameCompare("frame2.png", "frame02.png")
                == .orderedAscending
        )
        #expect(
            PetAssetLocator.naturalFrameNameCompare("frame2.png", "frame2.png")
                == .orderedSame
        )
    }
}
