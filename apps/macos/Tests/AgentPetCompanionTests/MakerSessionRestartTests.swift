import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Maker restart recovery")
struct MakerSessionRestartTests {
    @MainActor
    @Test
    func latestFailedCreateRestoresItsSessionAndEditableBrief() async {
        let store = makeStore { method, _, _ in
            #expect(method == "generation.latest")
            return Self.failedCreatePayload
        }

        await store.restoreLatestGenerationSessionIfNeeded()

        #expect(store.generationSession.state == .failed)
        #expect(store.generationSession.jobID == "job_failed_without_pet")
        #expect(store.generationSession.resultPetID == nil)
        #expect(store.generationSession.submittedForm?.description == "A recovered pixel pet")
        #expect(store.descriptionText == "A recovered pixel pet")
        #expect(store.selectedStyle == .pixel)
        #expect(store.selectedQuality == .standard)
        #expect(store.selectedNativeFPS == 20)
        #expect(store.generationStateDurationsMS == Self.recoveredDurations)
        #expect(store.referenceImages.isEmpty)
        #expect(store.referenceReselectionCount == 0)
        #expect(store.generationSession.canRetry)
    }

    @MainActor
    @Test
    func automaticRestoreNeverOverwritesABriefStartedDuringLaunch() async {
        let store = makeStore { _, _, _ in Self.failedCreatePayload }
        store.updateGenerationDescription("The user already started a new brief")

        await store.restoreLatestGenerationSessionIfNeeded()

        #expect(store.generationSession.state == .idle)
        #expect(store.generationSession.jobID == nil)
        #expect(store.descriptionText == "The user already started a new brief")
    }

    @MainActor
    @Test
    func automaticRestoreNeverReplacesAnActiveSnapshotSession() async {
        let store = makeStore { _, _, _ in Self.failedCreatePayload }
        _ = store.reduceGeneration(.restore(GenerationSessionRestore(
            state: .waitingForInput,
            jobID: "job_active_snapshot",
            submittedForm: GenerationForm(
                description: "Keep the active session",
                style: StylePreset.modern.rawValue,
                quality: .high,
                referenceImages: []
            ),
            messages: [],
            progress: 0.4,
            messageRevision: "4"
        )))

        await store.restoreLatestGenerationSessionIfNeeded()

        #expect(store.generationSession.state == .waitingForInput)
        #expect(store.generationSession.jobID == "job_active_snapshot")
        #expect(store.generationSession.submittedForm?.description == "Keep the active session")
    }

    @MainActor
    @Test
    func canceledAndCompletedSessionsRestoreWithoutInventingResultMetadata() async {
        for (status, expectedState, resultPetID) in [
            ("canceled", GenerationSessionState.cancelled, nil),
            ("completed", GenerationSessionState.succeeded, "pet_completed"),
        ] {
            let store = makeStore { _, _, _ in
                Self.sessionPayload(status: status, resultPetID: resultPetID)
            }

            await store.restoreLatestGenerationSessionIfNeeded()

            #expect(store.generationSession.state == expectedState)
            #expect(store.generationSession.resultPetID == resultPetID)
            if status == "canceled" {
                #expect(store.generationSession.resultRevisionID == nil)
                #expect(store.generationSession.validationSummary == nil)
            }
        }
    }

    @MainActor
    @Test
    func requestFailureAndMalformedFoundSessionRemainRetryable() async {
        var requestCount = 0
        let store = makeStore { _, _, _ in
            requestCount += 1
            switch requestCount {
            case 1:
                throw RestoreTestError.transient
            case 2:
                return ["found": true, "messages": []]
            default:
                return Self.failedCreatePayload
            }
        }

        await store.restoreLatestGenerationSessionIfNeeded()
        await store.restoreLatestGenerationSessionIfNeeded()
        await store.restoreLatestGenerationSessionIfNeeded()

        #expect(requestCount == 3)
        #expect(store.generationSession.state == .failed)
        #expect(store.generationSession.jobID == "job_failed_without_pet")
    }

    @MainActor
    @Test
    func validEmptyResponseResolvesRecoveryExactlyOnce() async {
        var requestCount = 0
        let store = makeStore { _, _, _ in
            requestCount += 1
            return ["ok": true, "found": false, "messages": []]
        }

        await store.restoreLatestGenerationSessionIfNeeded()
        await store.restoreLatestGenerationSessionIfNeeded()

        #expect(requestCount == 1)
        #expect(store.generationSession.state == .idle)
    }

    @MainActor
    @Test
    func concurrentRestoreCallersShareOneInFlightRequest() async {
        let gate = LatestGenerationRequestGate()
        let store = makeStore { _, _, _ in await gate.request() }
        let first = Task { @MainActor in
            await store.restoreLatestGenerationSessionIfNeeded()
        }
        await gate.waitUntilRequested()
        let second = Task { @MainActor in
            await store.restoreLatestGenerationSessionIfNeeded()
        }
        await Task.yield()

        gate.resume(with: Self.failedCreatePayload)
        await first.value
        await second.value

        #expect(gate.requestCount == 1)
        #expect(store.generationSession.jobID == "job_failed_without_pet")
    }

    @MainActor
    @Test
    func userMutationRevisionDefeatsAnAwaitedABAChange() async {
        let gate = LatestGenerationRequestGate()
        let store = makeStore { _, _, _ in await gate.request() }
        let task = Task { @MainActor in
            await store.restoreLatestGenerationSessionIfNeeded()
        }
        await gate.waitUntilRequested()

        store.updateGenerationDescription("temporary user brief")
        store.updateGenerationDescription(AIPetMakerDefaults.descriptionText)
        #expect(store.descriptionText == AIPetMakerDefaults.descriptionText)
        gate.resume(with: Self.failedCreatePayload)
        await task.value

        #expect(store.generationSession.state == .idle)
        #expect(store.generationSession.jobID == nil)
        #expect(store.descriptionText == AIPetMakerDefaults.descriptionText)
    }

    @MainActor
    @Test
    func everyDraftMutationInvalidatesAutomaticRecoveryEvenWhenItIsANoOp() async {
        let bundledPet = PetSummary(
            id: "pet_xingwutuanzi",
            name: "Bundled",
            style: StylePreset.semiRealistic.rawValue,
            quality: .high,
            renderSize: RenderSize(width: 384, height: 416),
            petpackPath: "/missing/bundled.petpack",
            coverPath: "/missing/cover.png",
            origin: .verifiedSkillSource,
            generator: "agent-pet-companion.release-inventory",
            provenance: "apc.bundled-pets.v1",
            active: false,
            createdAt: "2026-07-22T00:00:00Z"
        )
        let mutations: [(String, @MainActor (AppStore) -> Void)] = [
            ("description", { $0.updateGenerationDescription(AIPetMakerDefaults.descriptionText) }),
            ("style", { $0.selectGenerationStyle(.semiRealistic) }),
            ("quality", { $0.selectGenerationQuality(.high) }),
            ("native fps", { $0.selectGenerationNativeFPS(20) }),
            ("state duration", { $0.selectGenerationStateDuration(1_000, for: "idle") }),
            ("clear", { $0.clearStudioForm() }),
            ("new", { $0.showNewPetDraft() }),
            ("add", { $0.addReferenceImageURLs([]) }),
            ("remove", { $0.removeReferenceImage("/not-selected.png") }),
            ("customize", { $0.preparePetCustomizationCopy(bundledPet) }),
        ]

        for (label, mutation) in mutations {
            var requestCount = 0
            let store = makeStore { _, _, _ in
                requestCount += 1
                return Self.failedCreatePayload
            }
            mutation(store)

            await store.restoreLatestGenerationSessionIfNeeded()

            #expect(requestCount == 0, "\(label) must invalidate automatic recovery")
            #expect(store.generationSession.jobID == nil)
        }
    }

    @MainActor
    @Test
    func authoritativeActiveSnapshotWinsWithoutCallingLatestRecovery() async throws {
        var requestCount = 0
        let store = makeStore { _, _, _ in
            requestCount += 1
            return Self.failedCreatePayload
        }
        try store.applyStateSnapshot(Self.stateSnapshot(activeGeneration: [
            "job_id": "job_active_snapshot",
            "status": "waiting_for_user",
            "form": [
                "description": "Authoritative active brief",
                "style": StylePreset.modern.rawValue,
                "quality": QualityLevel.high.rawValue,
                "reference_images": [],
                "native_fps": 20,
                "state_durations_ms": Self.recoveredDurations,
            ],
            "reference_reselection_count": 0,
            "heartbeat_at": "2026-07-22T00:00:00Z",
            "message_revision": "2",
            "messages": [],
        ]))

        await store.restoreLatestGenerationSessionIfNeeded()

        #expect(requestCount == 0)
        #expect(store.generationSession.state == .waitingForInput)
        #expect(store.generationSession.jobID == "job_active_snapshot")
        #expect(store.descriptionText == "Authoritative active brief")
        #expect(store.selectedNativeFPS == 20)
        #expect(store.generationStateDurationsMS == Self.recoveredDurations)
    }

    @MainActor
    @Test
    func recoveryUsesOnlyJobScopedSafeCopiesAndRequiresMissingReferencesAgain() async throws {
        let directory = try Self.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let safeReference = try Self.writePNG(
            below: directory,
            relativePath: "generation-jobs/job_safe/input/references/reference-00.png"
        )
        let originalReference = try Self.writePNG(
            below: directory,
            relativePath: "private-original.png"
        )

        let safeStore = makeStore { _, _, _ in
            Self.failedPayload(
                jobID: "job_safe",
                references: [safeReference.path],
                reselectionCount: 0
            )
        }
        await safeStore.restoreLatestGenerationSessionIfNeeded()
        #expect(safeStore.referenceImages == [safeReference.path])
        #expect(safeStore.referenceReselectionCount == 0)

        let rejectedStore = makeStore { _, _, _ in
            Self.failedPayload(
                jobID: "job_rejected",
                references: [originalReference.path],
                reselectionCount: 0
            )
        }
        await rejectedStore.restoreLatestGenerationSessionIfNeeded()
        #expect(rejectedStore.referenceImages.isEmpty)
        #expect(rejectedStore.referenceReselectionCount == 1)
        #expect(rejectedStore.referenceImageIssue == .reselectionRequired(1))
        #expect(!rejectedStore.canRetryGeneration)

        let missingStore = makeStore { _, _, _ in
            Self.failedPayload(jobID: "job_missing", references: [], reselectionCount: 2)
        }
        await missingStore.restoreLatestGenerationSessionIfNeeded()
        #expect(missingStore.referenceImages.isEmpty)
        #expect(missingStore.referenceReselectionCount == 2)
        #expect(!missingStore.canRetryGeneration)

        let firstReplacement = try Self.writePNG(below: directory, relativePath: "replacement-1.png")
        let secondReplacement = try Self.writePNG(below: directory, relativePath: "replacement-2.png")
        missingStore.addReferenceImageURLs([firstReplacement, secondReplacement])
        #expect(missingStore.referenceReselectionCount == 0)
        #expect(missingStore.referenceImageIssue == nil)
        #expect(missingStore.canRetryGeneration)

        missingStore.removeReferenceImage(firstReplacement.path)
        #expect(missingStore.referenceReselectionCount == 1)
        #expect(missingStore.referenceImageIssue == .reselectionRequired(1))
        #expect(!missingStore.canRetryGeneration)
        missingStore.retryGeneration()
        #expect(missingStore.generationSession.state == .failed)
    }

    @MainActor
    @Test
    func unchangedActiveProjectionReusesItsValidatedFormUntilPetCoreChangesIt() throws {
        let directory = try Self.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let safeReference = try Self.writePNG(
            below: directory,
            relativePath: "generation-jobs/job_hot/input/references/reference-00.png"
        )
        let store = makeStore { _, _, _ in ["ok": true, "found": false, "messages": []] }
        var active: [String: Any] = [
            "job_id": "job_hot",
            "status": "running",
            "form": [
                "description": "Hot path",
                "style": StylePreset.pixel.rawValue,
                "quality": QualityLevel.standard.rawValue,
                "reference_images": [safeReference.path],
            ],
            "reference_reselection_count": 0,
            "heartbeat_at": "2026-07-22T00:00:00Z",
            "message_revision": "1",
            "messages": [],
        ]

        try store.applyStateSnapshot(Self.stateSnapshot(activeGeneration: active))
        #expect(store.referenceImages == [safeReference.path])

        try FileManager.default.removeItem(at: safeReference)
        try store.applyStateSnapshot(Self.stateSnapshot(activeGeneration: active))
        #expect(store.referenceImages == [safeReference.path])

        active["form"] = [
            "description": "Hot path",
            "style": StylePreset.pixel.rawValue,
            "quality": QualityLevel.standard.rawValue,
            "reference_images": [],
        ]
        active["reference_reselection_count"] = 1
        try store.applyStateSnapshot(Self.stateSnapshot(activeGeneration: active))
        #expect(store.referenceImages.isEmpty)
        #expect(store.referenceReselectionCount == 1)
    }

    @MainActor
    private func makeStore(
        request: @escaping AppStore.PetCoreRequestOverride
    ) -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: request
        )
    }

    private static func sessionPayload(
        status: String,
        resultPetID: String?
    ) -> [String: Any] {
        var payload = failedPayload(
            jobID: "job_\(status)",
            references: [],
            reselectionCount: 0
        )
        payload["status"] = status
        payload["result_pet_id"] = resultPetID ?? NSNull()
        payload["messages"] = [[
            "id": "msg_\(status)",
            "role": "assistant",
            "kind": "generation_\(status)",
            "content": "terminal",
            "progress": 1.0,
            "created_at": "2026-07-22T00:00:00Z",
        ]]
        if resultPetID != nil {
            payload["revision_id"] = "rev_completed"
            payload["validation_summary"] = [
                "ok": true,
                "state_count": 7,
                "frame_count": 120,
                "warning_count": 0,
            ]
        }
        return payload
    }

    private static func failedPayload(
        jobID: String,
        references: [String],
        reselectionCount: Int
    ) -> [String: Any] {
        [
            "ok": true,
            "found": true,
            "job_id": jobID,
            "status": "failed",
            "result_pet_id": NSNull(),
            "operation": "create",
            "form": [
                "description": "A recovered pixel pet",
                "style": StylePreset.pixel.rawValue,
                "quality": QualityLevel.standard.rawValue,
                "reference_images": references,
                "native_fps": 20,
                "state_durations_ms": recoveredDurations,
            ],
            "reference_reselection_count": reselectionCount,
            "message_revision": "3",
            "messages": [[
                "id": "msg_failed",
                "role": "assistant",
                "kind": "generation_failed",
                "content": "The generation stopped before producing a pet.",
                "progress": 1.0,
                "created_at": "2026-07-22T00:00:00Z",
            ]],
        ]
    }

    private static func stateSnapshot(
        activeGeneration: [String: Any]?
    ) throws -> [String: Any] {
        let behaviorData = try JSONEncoder().encode(BehaviorSettings())
        let behavior = try #require(
            JSONSerialization.jsonObject(with: behaviorData) as? [String: Any]
        )
        var snapshot: [String: Any] = [
            "revision": "snapshot-1",
            "behavior": behavior,
            "behavior_revision": "1",
            "pets": [],
            "events": [],
            "connections": [],
        ]
        if let activeGeneration {
            snapshot["active_generation"] = activeGeneration
        }
        return snapshot
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apc-maker-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writePNG(below root: URL, relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }

    @MainActor
    private static var failedCreatePayload: [String: Any] {
        failedPayload(
            jobID: "job_failed_without_pet",
            references: [],
            reselectionCount: 0
        )
    }

    private static let recoveredDurations: [String: Int] = [
        "idle": 1_000,
        "start": 2_000,
        "tool": 1_000,
        "waiting": 2_000,
        "review": 1_000,
        "done": 2_000,
        "failed": 1_000,
    ]
}

private enum RestoreTestError: Error {
    case transient
}

@MainActor
private final class LatestGenerationRequestGate {
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private var pendingResponse: [String: Any]?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    func request() async -> [String: Any] {
        requestCount += 1
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
            let waiters = requestWaiters
            requestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        return pendingResponse ?? ["ok": true, "found": false, "messages": []]
    }

    func waitUntilRequested() async {
        if responseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resume(with response: [String: Any]) {
        pendingResponse = response
        let continuation = responseContinuation
        responseContinuation = nil
        continuation?.resume()
    }
}
