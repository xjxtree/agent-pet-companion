import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Maker history actions")
struct MakerHistoryActionsTests {
    @MainActor
    @Test
    func workspaceSelectsTheUniqueUnfinishedTaskAndBlocksANewDraft() async {
        let store = makeStore { method, params, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([
                    Self.historyRecord(jobID: "job_completed", status: "completed"),
                    Self.historyRecord(jobID: "job_waiting", status: "waiting_for_user"),
                ])
            case "generation.history.detail":
                let jobID = (params as? [String: Any])?["job_id"] as? String
                return Self.historyDetail(
                    jobID: jobID ?? "missing",
                    status: jobID == "job_waiting" ? "waiting_for_user" : "completed"
                )
            case "generation.messages.list":
                return [
                    "ok": true,
                    "job_id": "job_waiting",
                    "messages": [],
                    "has_more": false,
                    "next_before_sequence": NSNull(),
                    "revision": "0",
                ]
            default:
                throw PetCoreClientError.invalidResponse
            }
        }

        await store.prepareMakerWorkspace()

        #expect(store.selectedGenerationHistoryJobID == "job_waiting")
        #expect(!store.makerDraftIsActive)
        store.beginMakerDraft()
        #expect(!store.makerDraftIsActive)
        #expect(store.selectedGenerationHistoryJobID == "job_waiting")
        #expect(store.statusText == APCLocalization.text(.studioWorkspaceActiveTaskBlocksNew))
    }

    @MainActor
    @Test
    func emptyWorkspaceStartsAnUntimedLocalDraft() async {
        let store = makeStore { method, _, _ in
            if method == "generation.history.list" {
                return Self.historyList([])
            }
            throw PetCoreClientError.invalidResponse
        }

        await store.prepareMakerWorkspace()

        #expect(store.makerDraftIsActive)
        #expect(store.selectedGenerationHistoryJobID == nil)
        #expect(store.generationSession.jobID == nil)
        #expect(store.generationSession.startedAt == nil)
    }

    @MainActor
    @Test
    func draftIsPreservedAcrossRefreshAndCanBeDiscardedBackToHistory() async {
        let store = makeStore { method, params, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([
                    Self.historyRecord(jobID: "job_completed", status: "completed"),
                ])
            case "generation.history.detail":
                let jobID = (params as? [String: Any])?["job_id"] as? String
                return Self.historyDetail(jobID: jobID ?? "missing", status: "completed")
            case "generation.messages.list":
                return [
                    "ok": true,
                    "job_id": "job_completed",
                    "messages": [],
                    "has_more": false,
                    "next_before_sequence": NSNull(),
                    "revision": "0",
                ]
            default:
                throw PetCoreClientError.invalidResponse
            }
        }

        await store.refreshGenerationHistory()
        store.updateGenerationDescription("stale previous brief")
        store.beginMakerDraft()
        #expect(store.makerDraftIsActive)
        #expect(store.descriptionText == AIPetMakerDefaults.descriptionText)

        store.updateGenerationDescription("keep this local draft")
        await store.prepareMakerWorkspace()
        #expect(store.makerDraftIsActive)
        #expect(store.descriptionText == "keep this local draft")

        store.discardMakerDraft()
        for _ in 0..<100 where store.generationHistoryDetail?.jobID != "job_completed" {
            await Task.yield()
        }
        #expect(!store.makerDraftIsActive)
        #expect(store.selectedGenerationHistoryJobID == "job_completed")
        #expect(store.descriptionText == AIPetMakerDefaults.descriptionText)
    }

    @MainActor
    @Test
    func copiesModifyHistoryIntoAnOrdinaryCreateDraftWithoutPrivateReferences() async {
        let store = makeStore { method, _, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([Self.historyRecord(
                    jobID: "job_copy",
                    status: "canceled",
                    operation: "modify",
                    referenceCount: 2,
                    resultPetID: "pet_original"
                )])
            case "generation.history.detail":
                return Self.historyDetail(
                    jobID: "job_copy",
                    status: "canceled",
                    operation: "modify",
                    description: "Make the ears rounder",
                    style: StylePreset.pixel.rawValue,
                    quality: QualityLevel.low.rawValue,
                    referenceCount: 2,
                    resultPetID: "pet_original"
                )
            default:
                throw PetCoreClientError.invalidResponse
            }
        }

        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_copy")

        #expect(store.copySelectedGenerationHistoryBriefToNewDraft())
        #expect(store.descriptionText == "Make the ears rounder")
        #expect(store.selectedStyle == .pixel)
        #expect(store.selectedQuality == .low)
        #expect(store.referenceImages.isEmpty)
        #expect(store.referenceReselectionCount == 2)
        #expect(store.referenceImageIssue == .reselectionRequired(2))
        #expect(store.generationSession.state == .idle)
        #expect(store.generationSession.operation == .create)
        #expect(store.generationSession.resultPetID == nil)
        #expect(store.makerDraftIsActive)
        #expect(store.selectedGenerationHistoryJobID == nil)
        #expect(store.generationHistoryDetail == nil)
    }

    @MainActor
    @Test
    func activeJobBlocksHistoryBriefCopyWithoutChangingTheDraft() async {
        let store = makeStore { method, _, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([
                    Self.historyRecord(jobID: "job_copy", status: "failed"),
                ])
            case "generation.history.detail":
                return Self.historyDetail(jobID: "job_copy", status: "failed")
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_copy")
        _ = store.reduceGeneration(.restore(GenerationSessionRestore(
            state: .running,
            jobID: "job_active",
            submittedForm: GenerationForm(
                description: "Keep this active work",
                style: StylePreset.modern.rawValue,
                quality: .standard,
                referenceImages: []
            ),
            messages: [],
            progress: 0.4,
            messageRevision: "1"
        )))

        #expect(!store.copySelectedGenerationHistoryBriefToNewDraft())
        #expect(store.generationSession.jobID == "job_active")
        #expect(store.generationSession.state == .running)
    }

    @MainActor
    @Test
    func retriesATerminalFailedCreateHistoryWithItsTypedBrief() async {
        var retryCalls = 0
        let store = makeStore { method, params, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([Self.historyRecord(
                    jobID: "job_failed",
                    status: "failed",
                    style: StylePreset.anime.rawValue,
                    quality: QualityLevel.low.rawValue
                )])
            case "generation.history.detail":
                return Self.historyDetail(
                    jobID: "job_failed",
                    status: "failed",
                    description: "A tiny cloud fox",
                    style: StylePreset.anime.rawValue,
                    quality: QualityLevel.low.rawValue
                )
            case "generation.retry":
                retryCalls += 1
                let object = try #require(params as? [String: Any])
                #expect(object["job_id"] as? String == "job_failed")
                let form = try #require(object["form"] as? [String: Any])
                #expect(form["description"] as? String == "A tiny cloud fox")
                #expect(form["style"] as? String == StylePreset.anime.rawValue)
                #expect(form["quality"] as? String == QualityLevel.low.rawValue)
                #expect((form["reference_images"] as? [String])?.isEmpty == true)
                return [
                    "ok": true,
                    "job_id": "job_retry",
                    "retry_of_job_id": "job_failed",
                    "operation": "create",
                ]
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_failed")

        store.retrySelectedGenerationHistory()
        for _ in 0..<100 where store.generationSession.jobID != "job_retry" {
            await Task.yield()
        }

        #expect(retryCalls == 1)
        #expect(store.generationSession.jobID == "job_retry")
        #expect(store.generationSession.state == .running)
        #expect(store.generationSession.operation == .create)
    }

    @MainActor
    @Test
    func historyRetryRequiresReferenceReselectionBeforeSendingTheRPC() async {
        var retryCalls = 0
        let store = makeStore { method, _, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([Self.historyRecord(
                    jobID: "job_references",
                    status: "failed",
                    referenceCount: 2
                )])
            case "generation.history.detail":
                return Self.historyDetail(
                    jobID: "job_references",
                    status: "failed",
                    referenceCount: 2
                )
            case "generation.retry":
                retryCalls += 1
                return ["ok": true, "job_id": "unexpected_retry"]
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_references")

        store.retrySelectedGenerationHistory()
        await Task.yield()

        #expect(retryCalls == 0)
        #expect(store.generationSession.jobID == nil)
        #expect(store.generationSession.state == .idle)
        #expect(store.referenceImages.isEmpty)
        #expect(store.referenceReselectionCount == 0)
        #expect(store.referenceImageIssue == nil)
        #expect(store.statusText == APCLocalization.format(
            .studioHistoryCopyBriefReferencesNoticeFormat,
            2
        ))
    }

    @MainActor
    @Test
    func modifyHistoryRetryPreservesServerOwnedEditContext() async {
        var retryParameters: [String: Any]?
        let store = makeStore { method, params, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([Self.historyRecord(
                    jobID: "job_modify",
                    status: "failed",
                    operation: "modify",
                    resultPetID: "pet_existing"
                )])
            case "generation.history.detail":
                return Self.historyDetail(
                    jobID: "job_modify",
                    status: "failed",
                    operation: "modify",
                    description: "Give the pet a blue scarf",
                    resultPetID: "pet_existing"
                )
            case "generation.retry":
                retryParameters = params as? [String: Any]
                return [
                    "ok": true,
                    "job_id": "job_modify_retry",
                    "retry_of_job_id": "job_modify",
                    "operation": "modify",
                    "baseline_revision_id": "rev_baseline",
                ]
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_modify")

        store.retrySelectedGenerationHistory()
        for _ in 0..<100 where store.generationSession.jobID != "job_modify_retry" {
            await Task.yield()
        }

        #expect(retryParameters?["job_id"] as? String == "job_modify")
        #expect(retryParameters?["form"] == nil)
        #expect(store.generationSession.jobID == "job_modify_retry")
        #expect(store.generationSession.operation == .modify)
        #expect(store.generationSession.resultPetID == "pet_existing")
        #expect(store.generationSession.baselineRevisionID == "rev_baseline")
    }

    @MainActor
    @Test
    func deletingSelectedHistoryRefreshesAndSelectsTheAdjacentRecord() async {
        var listCalls = 0
        var deletedJobID: String?
        let store = makeStore { method, params, _ in
            switch method {
            case "generation.history.list":
                listCalls += 1
                return Self.historyList(listCalls == 1 ? [
                    Self.historyRecord(
                        jobID: "job_a",
                        status: "completed",
                        resultPetID: "pet_retained"
                    ),
                    Self.historyRecord(jobID: "job_b", status: "canceled"),
                ] : [
                    Self.historyRecord(jobID: "job_b", status: "canceled"),
                ])
            case "generation.history.detail":
                let jobID = (params as? [String: Any])?["job_id"] as? String
                return Self.historyDetail(
                    jobID: jobID ?? "missing",
                    status: jobID == "job_b" ? "canceled" : "completed",
                    resultPetID: jobID == "job_a" ? "pet_retained" : nil
                )
            case "generation.history.delete":
                deletedJobID = (params as? [String: Any])?["job_id"] as? String
                return [
                    "ok": true,
                    "job_id": deletedJobID ?? "",
                    "deleted_status": "completed",
                    "deleted_message_count": 3,
                    "workspace_removed": true,
                    "retained_result_pet_id": "pet_retained",
                    "retry_children_relinked": 0,
                    "state_revision": "12",
                ]
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        store.pets = [Self.pet(id: "pet_retained", active: false)]
        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_a")

        let deleted = await store.deleteGenerationHistory(jobID: "job_a")

        #expect(deleted)
        #expect(deletedJobID == "job_a")
        #expect(listCalls == 2)
        #expect(store.generationHistorySnapshot.jobs.map(\.jobID) == ["job_b"])
        #expect(store.selectedGenerationHistoryJobID == "job_b")
        #expect(store.generationHistoryDetail?.jobID == "job_b")
        #expect(store.generationHistoryDeleteInFlightJobID == nil)
        #expect(store.generationHistoryMutationError == nil)
        #expect(store.pets.map(\.id) == ["pet_retained"])
    }

    @MainActor
    @Test
    func deletionFailureRemainsVisibleAndDoesNotDropTheRecord() async {
        enum DeletionFailure: Error { case rejected }
        let store = makeStore { method, _, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([
                    Self.historyRecord(jobID: "job_keep", status: "failed"),
                ])
            case "generation.history.detail":
                return Self.historyDetail(jobID: "job_keep", status: "failed")
            case "generation.history.delete":
                throw DeletionFailure.rejected
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_keep")

        let deleted = await store.deleteGenerationHistory(jobID: "job_keep")
        #expect(!deleted)
        #expect(store.generationHistorySnapshot.jobs.map(\.jobID) == ["job_keep"])
        #expect(store.selectedGenerationHistoryJobID == "job_keep")
        #expect(store.generationHistoryMutationError != nil)
        #expect(store.statusText == APCLocalization.format(
            .studioHistoryDeleteFailedFormat,
            store.generationHistoryMutationError ?? ""
        ))
    }

    @MainActor
    @Test
    func resultPetLookupActivationAndLibraryNavigationShareOneStorePath() async {
        var activatedPetID: String?
        let store = makeStore { method, params, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([Self.historyRecord(
                    jobID: "job_result",
                    status: "completed",
                    resultPetID: "pet_result"
                )])
            case "generation.history.detail":
                return Self.historyDetail(
                    jobID: "job_result",
                    status: "completed",
                    resultPetID: "pet_result"
                )
            case "pet.activate":
                activatedPetID = (params as? [String: Any])?["id"] as? String
                return ["ok": true]
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        store.pets = [Self.pet(id: "pet_result", active: false)]
        store.selection = .maker
        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_result")

        #expect(store.selectedGenerationHistoryResultPet?.id == "pet_result")
        #expect(!store.selectedGenerationHistoryResultPetIsActive)
        let openedResultPet = await store.showSelectedGenerationHistoryResultPetInLibrary()
        #expect(openedResultPet)
        #expect(activatedPetID == "pet_result")
        #expect(store.selectedGenerationHistoryResultPetIsActive)
        #expect(store.selection == .library)
    }

    @MainActor
    @Test
    func clearingHistorySelectionInvalidatesAnInFlightDetail() async {
        let gate = HistoryDetailGate()
        let store = makeStore { method, _, _ in
            switch method {
            case "generation.history.list":
                return Self.historyList([
                    Self.historyRecord(jobID: "job_stale", status: "failed"),
                ])
            case "generation.history.detail":
                return await gate.response()
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        await store.refreshGenerationHistory()
        let load = Task { @MainActor in
            await store.selectGenerationHistoryJobAndWait("job_stale")
        }
        await gate.waitUntilRequested()

        store.clearGenerationHistorySelection()
        gate.release(Self.historyDetail(jobID: "job_stale", status: "failed"))
        await load.value

        #expect(store.selectedGenerationHistoryJobID == nil)
        #expect(store.generationHistoryDetail == nil)
        #expect(!store.generationHistoryDetailIsLoading)
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
            petCoreRequestOverride: request,
            initialPetStudioCodexAvailability: .available
        )
    }

    private static func historyList(_ jobs: [[String: Any]]) -> [String: Any] {
        ["ok": true, "jobs": jobs, "truncated": false]
    }

    private static func historyRecord(
        jobID: String,
        status: String,
        operation: String = "create",
        style: String = StylePreset.semiRealistic.rawValue,
        quality: String = QualityLevel.standard.rawValue,
        referenceCount: Int = 0,
        resultPetID: String? = nil
    ) -> [String: Any] {
        [
            "job_id": jobID,
            "status": status,
            "operation": operation,
            "brief_preview": "A bounded brief",
            "style": style,
            "quality": quality,
            "reference_count": referenceCount,
            "result_pet_id": resultPetID ?? NSNull(),
            "retry_of_job_id": NSNull(),
            "created_at": "2026-08-07T00:00:00Z",
            "updated_at": "2026-08-07T00:01:00Z",
        ]
    }

    private static func historyDetail(
        jobID: String,
        status: String,
        operation: String = "create",
        description: String = "A bounded brief",
        style: String = StylePreset.semiRealistic.rawValue,
        quality: String = QualityLevel.standard.rawValue,
        referenceCount: Int = 0,
        resultPetID: String? = nil
    ) -> [String: Any] {
        [
            "ok": true,
            "found": true,
            "job_id": jobID,
            "status": status,
            "operation": operation,
            "description": description,
            "style": style,
            "quality": quality,
            "reference_count": referenceCount,
            "result_pet_id": resultPetID ?? NSNull(),
            "retry_of_job_id": NSNull(),
            "revision_id": NSNull(),
            "created_at": "2026-08-07T00:00:00Z",
            "updated_at": "2026-08-07T00:01:00Z",
            "progress_messages": [[
                "id": "message_\(jobID)",
                "role": "assistant",
                "kind": "generation_\(status)",
                "content": "Terminal task state",
                "progress": 1.0,
                "created_at": "2026-08-07T00:01:00Z",
            ]],
            "message_count": 1,
            "messages_truncated": false,
            "session": [
                "availability": "not_created",
                "can_open": false,
            ],
        ]
    }

    private static func pet(id: String, active: Bool) -> PetSummary {
        PetSummary(
            id: id,
            name: "Result Pet",
            style: StylePreset.semiRealistic.rawValue,
            quality: .standard,
            renderSize: RenderSize(width: 384, height: 416),
            petpackPath: "/tmp/\(id).petpack",
            coverPath: "/tmp/\(id).png",
            active: active,
            createdAt: "2026-08-07T00:00:00Z"
        )
    }
}

@MainActor
private final class HistoryDetailGate {
    private var requested = false
    private var responseValue: [String: Any]?

    func response() async -> [String: Any] {
        requested = true
        while responseValue == nil {
            await Task.yield()
        }
        return responseValue ?? [:]
    }

    func waitUntilRequested() async {
        while !requested {
            await Task.yield()
        }
    }

    func release(_ value: [String: Any]) {
        responseValue = value
    }
}
