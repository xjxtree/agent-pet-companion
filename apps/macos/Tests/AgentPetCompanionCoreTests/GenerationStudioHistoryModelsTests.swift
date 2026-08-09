import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite("Maker history transport models")
struct GenerationStudioHistoryModelsTests {
    @Test
    func historyRecordCarriesRowPresentationAndRetryMetadata() throws {
        let record = try JSONDecoder().decode(
            GenerationStudioHistoryRecord.self,
            from: Data(#"""
            {
              "job_id":"job_retry",
              "status":"completed",
              "operation":"create",
              "brief_preview":"A cloud fox",
              "style":"动漫",
              "quality":"low",
              "reference_count":2,
              "result_pet_id":"pet_result",
              "retry_of_job_id":"job_original",
              "created_at":"2026-08-07T00:00:00Z",
              "updated_at":"2026-08-07T00:01:00Z"
            }
            """#.utf8)
        )

        #expect(record.style == "动漫")
        #expect(record.quality == .low)
        #expect(record.referenceCount == 2)
        #expect(record.resultPetID == "pet_result")
        #expect(record.retryOfJobID == "job_original")
    }

    @Test
    func deletionResponsePreservesTheResultPetContract() throws {
        let response = try JSONDecoder().decode(
            GenerationStudioHistoryDeleteReceipt.self,
            from: Data(#"""
            {
              "ok":true,
              "job_id":"job_deleted",
              "deleted_status":"completed",
              "deleted_message_count":12,
              "workspace_removed":true,
              "retained_result_pet_id":"pet_result",
              "retry_children_relinked":2,
              "state_revision":"42"
            }
            """#.utf8)
        )

        #expect(response.ok)
        #expect(response.jobID == "job_deleted")
        #expect(response.deletedStatus == .completed)
        #expect(response.deletedMessageCount == 12)
        #expect(response.workspaceRemoved)
        #expect(response.retainedResultPetID == "pet_result")
        #expect(response.retryChildrenRelinked == 2)
        #expect(response.stateRevision == "42")
    }

    @Test
    func onlyTerminalFailureCanCreateARetryJob() {
        let form = GenerationForm(
            description: "Retry this",
            style: StylePreset.semiRealistic.rawValue,
            quality: .standard,
            referenceImages: []
        )
        #expect(GenerationSession(
            state: .failed,
            jobID: "job_failed",
            submittedForm: form
        ).canRetry)
        #expect(!GenerationSession(
            state: .succeeded,
            jobID: "job_completed",
            submittedForm: form
        ).canRetry)
        #expect(!GenerationSession(
            state: .cancelled,
            jobID: "job_canceled",
            submittedForm: form
        ).canRetry)
    }
}
