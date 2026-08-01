import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite("Product presentation models")
struct ProductPresentationModelsTests {
    @Test
    func lifecycleKeepsProtocolNamesAndMapsEveryEventKind() {
        #expect(ProductLifecycleState.allCases.map(\.rawValue) == [
            "idle",
            "start",
            "tool",
            "waiting",
            "review",
            "done",
            "failed",
        ])

        for eventKind in AgentEventKind.allCases {
            #expect(ProductLifecycleState(eventKind: eventKind).rawValue == eventKind.rawValue)
        }
    }

    @Test
    func navigationCapabilityDecodesUnknownValuesAsUnavailable() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        #expect(try decoder.decode(
            NavigationCapability.self,
            from: Data(#""future_route""#.utf8)
        ) == .unavailable)

        for capability in NavigationCapability.allCases {
            let data = try encoder.encode(capability)
            #expect(try decoder.decode(NavigationCapability.self, from: data) == capability)
        }
    }

    @Test
    func sessionNavigationFailsClosedWhenCapabilityIsMissingOrUnknown() throws {
        let decoder = JSONDecoder()
        let missing = try decoder.decode(
            AgentSessionNavigation.self,
            from: Data(#"{"session_open":true,"surface":"chatgpt_app"}"#.utf8)
        )
        let future = try decoder.decode(
            AgentSessionNavigation.self,
            from: Data(
                #"{"capability":"future_mutation","session_open":true,"surface":"chatgpt_app"}"#.utf8
            )
        )

        #expect(missing.capability == .unavailable)
        #expect(future.capability == .unavailable)
    }

    @Test
    func attentionPresetsOwnExactEventSets() {
        #expect(AttentionPreset.onlyWhenNeeded.enabledEvents == [
            .waiting,
            .review,
            .failed,
        ])
        #expect(AttentionPreset.standard.enabledEvents == [
            .start,
            .waiting,
            .review,
            .done,
            .failed,
        ])
        #expect(AttentionPreset.allActivity.enabledEvents == Set(AgentEventKind.allCases))
        #expect(AttentionPreset.custom.enabledEvents == nil)
    }

    @Test
    func attentionPresetResolutionAndApplicationAreDeterministic() {
        let initial = Dictionary(
            uniqueKeysWithValues: AgentEventKind.allCases.map { ($0, false) }
        )

        for preset in [
            AttentionPreset.onlyWhenNeeded,
            .standard,
            .allActivity,
        ] {
            let applied = preset.applying(to: initial)
            #expect(AttentionPreset.resolve(events: applied) == preset)
        }

        var custom = AttentionPreset.standard.applying(to: initial)
        custom[.done] = false
        #expect(AttentionPreset.resolve(events: custom) == .custom)
        #expect(AttentionPreset.custom.applying(to: custom) == custom)
    }

    @Test
    func behaviorAndConfigurationPresentationUseTheAttentionPreset() {
        var behavior = BehaviorSettings()
        behavior = behavior.applyingAttentionPreset(.onlyWhenNeeded)

        #expect(behavior.attentionPreset == .onlyWhenNeeded)

        let withPet = ConfigurationPresentation(
            behavior: behavior,
            activePet: pet()
        )
        #expect(withPet.attentionPreset == .onlyWhenNeeded)

        let missingPet = ConfigurationPresentation(
            behavior: behavior,
            activePet: nil
        )
        #expect(missingPet.attentionPreset == .onlyWhenNeeded)
    }

    @Test
    func primaryActionsRemainSemanticAndDoNotDependOnLocalizedText() {
        #expect(PetLibraryPrimaryAction.usePet != .createPet)
        #expect(PetMakerPrimaryAction.usePet != .continueEditing)
        #expect(AgentConnectionPrimaryAction.connect != .repair)
        #expect(ServiceDiagnosticsPrimaryAction.refresh != .recover)
    }

    private func pet() -> PetSummary {
        PetSummary(
            id: "pet-timing",
            name: "Pet",
            style: "modern",
            quality: .standard,
            renderSize: QualityLevel.standard.renderSize,
            petpackPath: "/tmp/pet.petpack",
            coverPath: "/tmp/cover.png",
            active: true,
            createdAt: "2026-07-23T00:00:00Z"
        )
    }
}
