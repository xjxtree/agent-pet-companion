import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Onboarding AppStore")
struct OnboardingAppStoreTests {
    @MainActor
    @Test
    func snapshotHydratesResumableProgressAndOmissionDoesNotInventLocalState() async throws {
        let omittedProbe = OnboardingRPCProbe()
        let omittedStore = makeStore(probe: omittedProbe)
        var omittedSnapshot = try omittedProbe.snapshot()
        omittedSnapshot.removeValue(forKey: "onboarding")
        try omittedStore.applyStateSnapshot(omittedSnapshot)

        #expect(omittedStore.onboarding == nil)
        #expect(!omittedStore.shouldPresentOnboarding)

        let probe = OnboardingRPCProbe(stage: .connectAgents, revision: 7)
        let store = try await makeOnlineStore(probe: probe)

        #expect(store.onboarding?.progress.stage == .connectAgents)
        #expect(store.onboarding?.revision == "7")
        #expect(store.shouldPresentOnboarding)
    }

    @MainActor
    @Test
    func malformedProjectedProgressFailsClosedWithoutReplacingTheLastGoodScene() async throws {
        let probe = OnboardingRPCProbe(stage: .connectAgents, revision: 3)
        let store = try await makeOnlineStore(probe: probe)
        var malformed = try probe.snapshot()
        var onboarding = try #require(malformed["onboarding"] as? [String: Any])
        var progress = try #require(onboarding["progress"] as? [String: Any])
        progress["future_field"] = true
        onboarding["progress"] = progress
        malformed["onboarding"] = onboarding

        #expect(throws: (any Error).self) {
            try store.applyStateSnapshot(malformed)
        }
        #expect(store.onboarding?.progress.stage == .connectAgents)
        #expect(store.onboarding?.revision == "3")
    }

    @MainActor
    @Test
    func inactiveBundledPetMustReallyActivateBeforeTheSceneAdvances() async throws {
        let pet = bundledPet(active: false)
        let probe = OnboardingRPCProbe(pets: [pet])
        probe.failPetActivation = true
        let store = try await makeOnlineStore(probe: probe)

        let advanced = await store.confirmOnboardingPet(pet)

        #expect(!advanced)
        #expect(store.onboarding?.progress.stage == .choosePet)
        #expect(store.onboarding?.revision == "0")
        #expect(probe.onboardingWorkflowMethods == ["pet.activate"])
        #expect(store.onboardingOperationFailure == .petActivation)
    }

    @MainActor
    @Test
    func successfulActivationUsesTheSharedAwaitablePathBeforeCASUpdate() async throws {
        let pet = bundledPet(active: false)
        let probe = OnboardingRPCProbe(pets: [pet])
        let store = try await makeOnlineStore(probe: probe)

        let advanced = await store.confirmOnboardingPet(pet)

        #expect(advanced)
        #expect(store.onboarding?.progress.stage == .connectAgents)
        #expect(store.onboarding?.revision == "1")
        #expect(probe.expectedOnboardingRevisions == ["0"])
        #expect(probe.onboardingWorkflowMethods == [
            "pet.activate",
            "state.snapshot",
            "onboarding.update",
        ])
        #expect(store.activePet?.id == pet.id)
    }

    @MainActor
    @Test
    func existingActiveBundledPetAdvancesWithoutASecondActivation() async throws {
        let pet = bundledPet(active: true)
        let probe = OnboardingRPCProbe(pets: [pet])
        let store = try await makeOnlineStore(probe: probe)

        #expect(await store.confirmOnboardingPet(pet))
        #expect(probe.onboardingWorkflowMethods == ["onboarding.update"])
        #expect(store.onboarding?.progress.stage == .connectAgents)
    }

    @MainActor
    @Test
    func serviceInterruptionKeepsTheCurrentRevisionAndDisablesMutation() async throws {
        let probe = OnboardingRPCProbe(stage: .connectAgents, revision: 4)
        let store = makeStore(probe: probe)
        try store.applyStateSnapshot(probe.snapshot())

        let advanced = await store.advanceOnboarding(to: .demo)

        #expect(!advanced)
        #expect(store.onboarding?.progress.stage == .connectAgents)
        #expect(store.onboarding?.revision == "4")
        #expect(probe.methods.isEmpty)
        #expect(store.onboardingOperationFailure == .serviceUnavailable)
    }

    @MainActor
    @Test
    func revisionConflictRefreshesAndAcceptsAnEquivalentRemoteAdvance() async throws {
        let probe = OnboardingRPCProbe(stage: .connectAgents, revision: 8)
        probe.conflictingRemoteStage = .demo
        let store = try await makeOnlineStore(probe: probe)

        let advanced = await store.advanceOnboarding(to: .demo)

        #expect(advanced)
        #expect(probe.expectedOnboardingRevisions == ["8"])
        #expect(probe.onboardingWorkflowMethods == ["onboarding.update", "state.snapshot"])
        #expect(store.onboarding?.progress.stage == .demo)
        #expect(store.onboarding?.revision == "9")
        #expect(store.onboardingOperationFailure == nil)
    }

    @MainActor
    @Test
    func explicitSkipPersistsAClosedTerminalStateWithoutTouchingThePet() async throws {
        let pet = bundledPet(active: true)
        let probe = OnboardingRPCProbe(
            stage: .connectAgents,
            revision: 1,
            pets: [pet]
        )
        let store = try await makeOnlineStore(probe: probe)

        #expect(await store.advanceOnboarding(to: .skipped))
        #expect(store.onboarding?.progress.stage == .skipped)
        #expect(!store.shouldPresentOnboarding)
        #expect(probe.onboardingWorkflowMethods == ["onboarding.update"])
        #expect(store.activePet?.id == pet.id)
    }

    @MainActor
    @Test
    func completionPublishesOnlyWithTheSnapshotThatLeavesThePetVisible() async throws {
        let pet = bundledPet(active: true)
        let probe = OnboardingRPCProbe(
            stage: .demo,
            revision: 2,
            behavior: BehaviorSettings(enabled: false),
            pets: [pet]
        )
        let store = try await makeOnlineStore(probe: probe)
        #expect(!store.behavior.enabled)

        let completed = await store.advanceOnboarding(to: .completed)

        #expect(completed)
        #expect(probe.onboardingWorkflowMethods == ["onboarding.update", "state.snapshot"])
        #expect(store.onboarding?.progress.stage == .completed)
        #expect(store.behavior.enabled)
        #expect(store.overlayVisibility.petVisible)
        #expect(!store.shouldPresentOnboarding)
    }

    @MainActor
    private func makeOnlineStore(
        probe: OnboardingRPCProbe
    ) async throws -> AppStore {
        let store = makeStore(probe: probe)
        await store.bootstrapIfNeeded()
        try store.applyStateSnapshot(probe.snapshot())
        return store
    }

    @MainActor
    private func makeStore(probe: OnboardingRPCProbe) -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { store in
                    try store.applyStateSnapshot(probe.snapshot())
                },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { _ in },
            overlayPresenter: { _, _ in },
            petCoreRequestOverride: { method, params, _ in
                try probe.request(method: method, params: params)
            }
        )
    }

    private func bundledPet(active: Bool) -> PetSummary {
        PetSummary(
            id: "pet_xingwutuanzi",
            name: "星雾团子",
            style: "半写实",
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: "/tmp/pet_xingwutuanzi.petpack",
            coverPath: "/tmp/pet_xingwutuanzi-cover.png",
            origin: .verifiedSkillSource,
            generator: "agent-pet-companion.release-inventory",
            provenance: "apc.bundled-pets.v1",
            nativeFPS: 20,
            active: active,
            createdAt: "2026-07-23T00:00:00Z"
        )
    }
}

@MainActor
private final class OnboardingRPCProbe {
    var stage: OnboardingStage
    var revision: UInt64
    var behavior: BehaviorSettings
    var pets: [PetSummary]
    var failPetActivation = false
    var conflictingRemoteStage: OnboardingStage?
    var methods: [String] = []
    var expectedOnboardingRevisions: [String] = []

    var onboardingWorkflowMethods: [String] {
        methods.filter {
            $0 == "pet.activate"
                || $0 == "state.snapshot"
                || $0 == "onboarding.update"
        }
    }

    init(
        stage: OnboardingStage = .choosePet,
        revision: UInt64 = 0,
        behavior: BehaviorSettings = BehaviorSettings(),
        pets: [PetSummary] = []
    ) {
        self.stage = stage
        self.revision = revision
        self.behavior = behavior
        self.pets = pets
    }

    func request(method: String, params: Any) throws -> Any {
        methods.append(method)
        switch method {
        case "pet.activate":
            if failPetActivation {
                throw NSError(
                    domain: "OnboardingRPCProbe",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "activation rejected"]
                )
            }
            let values = try #require(params as? [String: Any])
            let id = try #require(values["id"] as? String)
            guard let index = pets.firstIndex(where: { $0.id == id }) else {
                throw PetCoreClientError.rpcError("unknown pet")
            }
            for petIndex in pets.indices {
                pets[petIndex].active = petIndex == index
            }
            return ["id": id]
        case "state.snapshot":
            return try snapshot()
        case "onboarding.update":
            let values = try #require(params as? [String: Any])
            let expected = try #require(values["expected_revision"] as? String)
            expectedOnboardingRevisions.append(expected)

            if let conflictingRemoteStage {
                self.conflictingRemoteStage = nil
                stage = conflictingRemoteStage
                revision &+= 1
                throw PetCoreClientError.rpcError("onboarding revision conflict")
            }

            guard expected == String(revision) else {
                throw PetCoreClientError.rpcError("onboarding revision conflict")
            }
            let progressObject = try #require(values["progress"])
            let progressData = try JSONSerialization.data(
                withJSONObject: progressObject
            )
            let progress = try JSONDecoder().decode(
                OnboardingProgress.self,
                from: progressData
            )
            guard stage.canAdvance(to: progress.stage) else {
                throw PetCoreClientError.rpcError("invalid onboarding transition")
            }
            stage = progress.stage
            revision &+= 1
            if stage == .completed {
                behavior.enabled = true
            }
            return try jsonObject(VersionedOnboardingProgress(
                progress: progress,
                revision: String(revision)
            ))
        case "overlay.placement.update":
            return params
        case "generation.latest":
            return ["found": false]
        default:
            throw PetCoreClientError.rpcError("unexpected method \(method)")
        }
    }

    func snapshot() throws -> [String: Any] {
        [
            "revision": String(revision),
            "changed": true,
            "behavior": try jsonObject(behavior),
            "behavior_revision": String(revision),
            "onboarding": try jsonObject(VersionedOnboardingProgress(
                progress: OnboardingProgress(stage: stage),
                revision: String(revision)
            )),
            "pets": try jsonArray(pets),
            "events": [],
            "recent_events": [],
            "connections": [],
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func jsonArray<T: Encodable>(_ value: T) throws -> [Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [Any])
    }
}
