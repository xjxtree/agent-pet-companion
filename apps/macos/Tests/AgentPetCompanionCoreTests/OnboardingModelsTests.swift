import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite("Onboarding models")
struct OnboardingModelsTests {
    @Test
    func progressRoundTripsEveryClosedStageWithTheExactSchema() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for stage in OnboardingStage.allCases {
            let progress = OnboardingProgress(stage: stage)
            let encoded = try encoder.encode(progress)
            let decoded = try decoder.decode(OnboardingProgress.self, from: encoded)

            #expect(decoded == progress)
            #expect(decoded.schemaVersion == "apc.onboarding-progress.v1")
        }
    }

    @Test
    func progressAndRevisionFailClosedForFutureOrMalformedInput() {
        let decoder = JSONDecoder()
        let invalidPayloads = [
            #"{"schema_version":"apc.onboarding-progress.v2","stage":"choose_pet"}"#,
            #"{"schema_version":"apc.onboarding-progress.v1","stage":"future_scene"}"#,
            #"{"schema_version":"apc.onboarding-progress.v1","stage":"choose_pet","extra":true}"#,
        ]

        for payload in invalidPayloads {
            #expect(throws: (any Error).self) {
                try decoder.decode(
                    OnboardingProgress.self,
                    from: Data(payload.utf8)
                )
            }
        }

        for revision in ["", "-1", "1.0", "18446744073709551616"] {
            let payload =
                #"{"progress":{"schema_version":"apc.onboarding-progress.v1","stage":"choose_pet"},"revision":"\#(revision)"}"#
            #expect(throws: (any Error).self) {
                try decoder.decode(
                    VersionedOnboardingProgress.self,
                    from: Data(payload.utf8)
                )
            }
        }

        #expect(throws: (any Error).self) {
            try decoder.decode(
                VersionedOnboardingProgress.self,
                from: Data(
                    #"{"progress":{"schema_version":"apc.onboarding-progress.v1","stage":"choose_pet"},"revision":"0","future":true}"#.utf8
                )
            )
        }
    }

    @Test
    func transitionsAreSequentialWithExplicitTerminalSkip() {
        #expect(OnboardingStage.choosePet.canAdvance(to: .connectAgents))
        #expect(OnboardingStage.connectAgents.canAdvance(to: .demo))
        #expect(OnboardingStage.demo.canAdvance(to: .completed))

        for stage in [OnboardingStage.choosePet, .connectAgents, .demo] {
            #expect(stage.canAdvance(to: .skipped))
            #expect(!stage.isTerminal)
        }

        for terminal in [OnboardingStage.completed, .skipped] {
            #expect(terminal.isTerminal)
            #expect(!OnboardingStage.allCases.contains {
                terminal.canAdvance(to: $0)
            })
        }

        #expect(!OnboardingStage.choosePet.canAdvance(to: .demo))
        #expect(!OnboardingStage.connectAgents.canAdvance(to: .completed))
        #expect(!OnboardingStage.demo.canAdvance(to: .connectAgents))
    }

    @Test
    func localDemoHasExactlyFourForwardOnlyProductStates() {
        var demo = OnboardingDemoSequence()
        var observed = [demo.phase]
        for _ in 0..<4 {
            observed.append(demo.advance())
        }

        #expect(observed == [
            .thinking,
            .working,
            .needsAttention,
            .done,
            .done,
        ])
        #expect(OnboardingDemoPhase.allCases.map(\.lifecycleState) == [
            .start,
            .tool,
            .waiting,
            .done,
        ])
        #expect(demo.isComplete)

        demo.reset()
        #expect(demo.phase == .thinking)
        #expect(!demo.isComplete)
    }

    @Test
    func chooseSceneUsesStableIncludedIdentitiesWithoutGrantingBundledAuthority() {
        let bundled = bundledPet(
            id: "pet_xingwutuanzi",
            name: "星雾团子"
        )
        let preservedUpgradePet = pet(
            id: "pet_bytebudcodex",
            name: "Preserved Bytebud"
        )
        let custom = pet(id: "pet_custom", name: "Custom")

        let noSelection = presentation(
            stage: .choosePet,
            pets: [custom, preservedUpgradePet, bundled],
            selectedPetID: custom.id
        )
        #expect(noSelection.pets.map(\.id) == [
            bundled.id,
            preservedUpgradePet.id,
        ])
        #expect(noSelection.selectedPetID == nil)
        #expect(noSelection.primaryAction == nil)
        #expect(!preservedUpgradePet.isBundled)
        #expect(preservedUpgradePet.isIncludedCompanionCandidate)

        let selected = presentation(
            stage: .choosePet,
            pets: [custom, preservedUpgradePet, bundled],
            selectedPetID: preservedUpgradePet.id
        )
        #expect(selected.primaryAction == .confirmPet)

        let unavailable = presentation(
            stage: .choosePet,
            pets: [preservedUpgradePet, bundled],
            selectedPetID: preservedUpgradePet.id,
            unavailablePetIDs: [preservedUpgradePet.id]
        )
        #expect(unavailable.selectedPetID == nil)
        #expect(unavailable.primaryAction == nil)
    }

    @Test
    func serviceInterruptionPreservesTheSceneButDisablesMutation() {
        let interrupted = presentation(
            stage: .connectAgents,
            availability: .serviceUnavailable,
            connectionState: .noAgents
        )

        #expect(interrupted.progress.stage == .connectAgents)
        #expect(interrupted.primaryAction == nil)
        #expect(!interrupted.allowsSkip)
        #expect(interrupted.allowsClose)
    }

    @Test
    func agentDetectionNeverBlocksTheLocalDemo() {
        let checking = presentation(
            stage: .connectAgents,
            connectionState: .checking
        )
        let noAgents = presentation(
            stage: .connectAgents,
            connectionState: .noAgents
        )

        #expect(checking.primaryAction == .continueToDemo)
        #expect(noAgents.primaryAction == .continueToDemo)
    }

    @Test
    func repairableAgentKeepsTheTypedHealthAndAction() throws {
        let repairable = try #require(OnboardingAgentPresentation(
            source: .codex,
            health: .needsRepair,
            primaryAction: .repair
        ))
        let scene = presentation(
            stage: .connectAgents,
            connectionState: .agents([repairable])
        )

        #expect(scene.primaryAction == .continueToDemo)
        guard case let .agents(agents) = scene.connectionState else {
            Issue.record("Expected an Agent scene")
            return
        }
        #expect(agents == [repairable])
        #expect(agents[0].health == .needsRepair)
        #expect(agents[0].primaryAction == .repair)
        #expect(OnboardingAgentPresentation(
            source: .codex,
            health: .checking,
            primaryAction: .verify
        ) == nil)
    }

    @Test
    func completionRequiresTheLocalDemoToReachDone() {
        var demo = OnboardingDemoSequence()
        var scene = presentation(stage: .demo, demoSequence: demo)
        #expect(scene.primaryAction == nil)

        while !demo.isComplete {
            demo.advance()
        }
        scene = presentation(stage: .demo, demoSequence: demo)
        #expect(scene.primaryAction == .finish)

        let completed = presentation(stage: .completed, demoSequence: demo)
        #expect(completed.primaryAction == nil)
        #expect(!completed.allowsSkip)
        #expect(!completed.allowsClose)
    }

    private func presentation(
        stage: OnboardingStage,
        availability: OnboardingFlowAvailability = .ready,
        pets: [PetSummary] = [],
        selectedPetID: String? = nil,
        unavailablePetIDs: Set<String> = [],
        connectionState: OnboardingConnectionSceneState = .checking,
        demoSequence: OnboardingDemoSequence = .init()
    ) -> OnboardingFlowPresentation {
        OnboardingFlowPresentation(
            progress: OnboardingProgress(stage: stage),
            availability: availability,
            pets: pets,
            selectedPetID: selectedPetID,
            unavailablePetIDs: unavailablePetIDs,
            connectionState: connectionState,
            demoSequence: demoSequence
        )
    }

    private func bundledPet(id: String, name: String) -> PetSummary {
        var value = pet(id: id, name: name)
        value.origin = .verifiedSkillSource
        value.generator = "agent-pet-companion.release-inventory"
        value.provenance = "apc.bundled-pets.v1"
        return value
    }

    private func pet(id: String, name: String) -> PetSummary {
        PetSummary(
            id: id,
            name: name,
            style: "modern",
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: "/tmp/\(id).petpack",
            coverPath: "/tmp/\(id)-cover.png",
            nativeFPS: 20,
            active: false,
            createdAt: "2026-07-23T00:00:00Z"
        )
    }
}
