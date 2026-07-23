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
    func behaviorAndConfigurationPresentationUsePresetAndValidatedNativeRate() {
        var behavior = BehaviorSettings(fpsProfile: .smooth)
        behavior = behavior.applyingAttentionPreset(.onlyWhenNeeded)
        let standardPet = pet(nativeFPS: 10)
        let smoothPet = pet(nativeFPS: 20)

        #expect(behavior.attentionPreset == .onlyWhenNeeded)

        let standard = ConfigurationPresentation(
            behavior: behavior,
            activePet: standardPet
        )
        #expect(standard.attentionPreset == .onlyWhenNeeded)
        #expect(standard.supportedPlaybackProfiles == [.standard])
        #expect(standard.selectedPlaybackProfile == .standard)

        let smooth = ConfigurationPresentation(
            behavior: behavior,
            activePet: smoothPet
        )
        #expect(smooth.supportedPlaybackProfiles == [.standard, .smooth])
        #expect(smooth.selectedPlaybackProfile == .smooth)

        let missingPet = ConfigurationPresentation(
            behavior: behavior,
            activePet: nil
        )
        #expect(missingPet.supportedPlaybackProfiles == [.standard])
        #expect(missingPet.selectedPlaybackProfile == .standard)
    }

    @Test
    func primaryActionsRemainSemanticAndDoNotDependOnLocalizedText() {
        #expect(PetLibraryPrimaryAction.usePet != .createPet)
        #expect(PetMakerPrimaryAction.usePet != .continueEditing)
        #expect(AgentConnectionPrimaryAction.connect != .repair)
        #expect(ServiceDiagnosticsPrimaryAction.refresh != .recover)
    }

    private func pet(nativeFPS: Int) -> PetSummary {
        PetSummary(
            id: "pet-\(nativeFPS)",
            name: "Pet",
            style: "modern",
            quality: .standard,
            renderSize: RenderSize(width: 192, height: 208),
            petpackPath: "/tmp/pet.petpack",
            coverPath: "/tmp/cover.png",
            nativeFPS: nativeFPS,
            active: true,
            createdAt: "2026-07-23T00:00:00Z"
        )
    }
}
