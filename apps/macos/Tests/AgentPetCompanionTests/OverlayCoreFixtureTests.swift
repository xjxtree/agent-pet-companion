import AgentPetCompanionCore
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("Overlay core visual fixture model")
struct OverlayCoreFixtureTests {
    @Test
    func everyFixtureStateResolvesToTheProductionPetStateName() {
        let resolved = UINextOverlayFixtureState.allCases.map { state in
            OverlayCoreFixtureModel(
                state: state,
                source: .codex,
                requestedActiveSessionCount: 1
            ).petStateName
        }

        #expect(resolved == [
            "idle",
            AgentEventKind.start.petState,
            AgentEventKind.tool.petState,
            AgentEventKind.waiting.petState,
            AgentEventKind.review.petState,
            AgentEventKind.done.petState,
            AgentEventKind.failed.petState,
        ])
    }

    @Test
    func fixturePetUsesReadableDeterministicAssetsForEveryResolvedState() throws {
        let pet = OverlayCoreFixturePet.bytebud

        #expect(pet.id == "pet_bytebudcodex")
        #expect(pet.isBundled)
        #expect(PetAssetLocator.coverURL(for: pet) != nil)
        for state in UINextOverlayFixtureState.allCases {
            let model = OverlayCoreFixtureModel(
                state: state,
                source: .codex,
                requestedActiveSessionCount: 1
            )
            let frames = PetAssetLocator.frameURLs(
                for: pet,
                stateName: model.petStateName
            )
            #expect(frames.count == 1)
            #expect(frames.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) })
        }
    }

    @Test
    func fixtureUsesTheProductionPetStageWithoutAnAppStoreDependency() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "apps/macos/Sources/AgentPetCompanion/Overlay/OverlayRootView.swift"
        ))
        let fixtureStart = try #require(source.range(of: "struct OverlayCoreFixtureView"))
        let fixtureEnd = try #require(
            source.range(of: "\n#endif", range: fixtureStart.upperBound ..< source.endIndex)
        )
        let fixtureSource = source[fixtureStart.lowerBound ..< fixtureEnd.lowerBound]
        #expect(fixtureSource.contains("PetStage("))
        #expect(fixtureSource.contains("pet: OverlayCoreFixturePet.bytebud"))
        #expect(!fixtureSource.contains("pawprint.fill"))

        let rendererStart = try #require(source.range(of: "private struct PetFrameLayerView"))
        let rendererEnd = try #require(
            source.range(
                of: "private struct PetMenuButton",
                range: rendererStart.upperBound ..< source.endIndex
            )
        )
        let rendererSource = source[rendererStart.lowerBound ..< rendererEnd.lowerBound]
        #expect(!rendererSource.contains("@EnvironmentObject"))
        #expect(rendererSource.contains("onVisualEnvelopeChanged"))
    }

    @Test
    func zeroOneAndEightSessionsRemainDistinctAndBounded() throws {
        let zero = OverlayCoreFixtureModel(
            state: .tool,
            source: .codex,
            requestedActiveSessionCount: 0
        )
        #expect(zero.resolvedActiveSessionCount == 0)
        #expect(zero.bubbleContent == nil)
        #expect(zero.visibleSessionRowCount == 0)

        let one = OverlayCoreFixtureModel(
            state: .tool,
            source: .codex,
            requestedActiveSessionCount: 1
        )
        #expect(one.resolvedActiveSessionCount == 1)
        #expect(try #require(one.bubbleContent).sessionCount == 1)
        #expect(one.visibleSessionRowCount == 1)

        let eight = OverlayCoreFixtureModel(
            state: .tool,
            source: .codex,
            requestedActiveSessionCount: 8
        )
        #expect(eight.resolvedActiveSessionCount == 8)
        #expect(try #require(eight.bubbleContent).sessionCount == 8)
        // Production collapsed groups show the newest non-attention session.
        #expect(eight.visibleSessionRowCount == 1)

        let clamped = OverlayCoreFixtureModel(
            state: .tool,
            source: .codex,
            requestedActiveSessionCount: 12
        )
        #expect(clamped.resolvedActiveSessionCount == 8)
    }

    @Test
    func attentionStateKeepsAllEightFixtureRowsVisible() throws {
        let waiting = OverlayCoreFixtureModel(
            state: .waiting,
            source: .claudeCode,
            requestedActiveSessionCount: 8
        )
        let content = try #require(waiting.bubbleContent)

        #expect(content.sessionCount == 8)
        #expect(content.visibleSessions.count == 8)
        #expect(waiting.visibleSessionRowCount == 8)
        #expect(content.sessions.allSatisfy { $0.eventType == .waiting })
    }

    @Test
    func idleStateNeverInventsAnActiveSession() {
        let idle = OverlayCoreFixtureModel(
            state: .idle,
            source: .pi,
            requestedActiveSessionCount: 8
        )

        #expect(idle.petStateName == "idle")
        #expect(idle.resolvedActiveSessionCount == 0)
        #expect(idle.bubbleContent == nil)
        #expect(idle.visibleSessionRowCount == 0)
    }
}
