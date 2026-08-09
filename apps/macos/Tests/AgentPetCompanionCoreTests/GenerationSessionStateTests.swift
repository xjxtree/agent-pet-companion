import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct GenerationSessionStateTests {
    @Test("generation forms contain only user-authored maker inputs")
    func generationFormCodableContract() throws {
        let form = GenerationForm(
            description: "A small pixel companion",
            style: "像素",
            quality: .low,
            referenceImages: ["/tmp/reference.png"]
        )

        let encoded = try JSONEncoder().encode(form)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(object.keys) == [
            "description",
            "style",
            "quality",
            "reference_images",
        ])
        #expect(try JSONDecoder().decode(GenerationForm.self, from: encoded) == form)
    }

    @Test("pet summaries require the complete nine-action timing contract")
    func petSummaryRejectsMissingTimingContract() {
        let json = #"{"id":"pet","name":"Pet","style":"像素","quality":"standard","render_size":{"width":384,"height":416},"petpack_path":"/tmp/pet.petpack","cover_path":"/tmp/cover.png","active":false,"created_at":"2026-07-31T00:00:00Z"}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PetSummary.self, from: Data(json.utf8))
        }
    }

    @Test("a pet without a private generation job decodes as empty history")
    func missingGenerationHistoryDecodes() throws {
        let data = Data(#"{"found":false,"ok":true,"pet_id":"pet_external"}"#.utf8)

        let history = try JSONDecoder().decode(GenerationHistory.self, from: data)

        #expect(!history.found)
        #expect(history.petId == "pet_external")
        #expect(history.jobId == nil)
        #expect(history.messages.isEmpty)
        #expect(history.revisionId == nil)
        #expect(history.validationSummary == nil)
    }

    @Test("Maker history detail exposes only a verified routable Studio thread")
    func studioHistoryDetailDecodesVerifiedNavigation() throws {
        let data = Data(#"""
        {
          "ok":true,
          "found":true,
          "job_id":"job_history",
          "status":"failed",
          "operation":"create",
          "description":"A small fox",
          "style":"半写实",
          "quality":"standard",
          "reference_count":1,
          "created_at":"2026-08-07T00:00:00Z",
          "updated_at":"2026-08-07T00:01:00Z",
          "progress_messages":[{"id":"msg_progress","job_id":"job_history","sequence":2,"role":"assistant","kind":"generation_progress","content":"Preparing","progress":0.1,"created_at":"2026-08-07T00:00:01Z"}],
          "latest_codex_excerpt":"Bounded excerpt",
          "message_count":3,
          "messages_truncated":false,
          "session":{"availability":"available","can_open":true,"routable_session_id":"019f5b0f-88ff-7413-8953-29de4ed0951c","name":"Agent Pet Studio · A small fox"}
        }
        """#.utf8)

        let detail = try JSONDecoder().decode(GenerationStudioHistoryDetail.self, from: data)

        #expect(detail.found)
        #expect(detail.status == .failed)
        #expect(detail.referenceCount == 1)
        #expect(detail.progressMessages.map(\.id) == ["msg_progress"])
        #expect(detail.session.availability == .available)
        #expect(detail.session.canOpen)
        #expect(
            detail.session.routableSessionID
                == "019f5b0f-88ff-7413-8953-29de4ed0951c"
        )
    }

    @Test("input_request remains an active generation session")
    func inputRequestRemainsActive() {
        var session = runningSession()

        let effects = session.reduce(.messagesReceived(
            [message(id: "msg_input", kind: "input_request", progress: 0.24)],
            revision: "2"
        ))

        #expect(session.state == .waitingForInput)
        #expect(session.isActive)
        #expect(session.canCancel)
        #expect(session.canSendReply)
        #expect(!effects.contains(.stopMessageStream))
    }

    @Test("a waiting job restores after restart and resumes its stream")
    func waitingJobRestoresAfterRestart() {
        let inputRequest = message(id: "msg_restore", kind: "input_request", progress: 0.31)
        let restore = GenerationSessionRestore(
            state: .waitingForInput,
            jobID: "job_restore",
            submittedForm: form(description: "Original submitted prompt"),
            messages: [inputRequest],
            progress: 0.31,
            messageRevision: "7"
        )
        var session = GenerationSession()

        let effects = session.reduce(.restore(restore))

        #expect(session.state == .waitingForInput)
        #expect(session.jobID == "job_restore")
        #expect(session.submittedForm?.description == "Original submitted prompt")
        #expect(session.messages.map(\.id) == ["msg_restore"])
        #expect(session.canCancel)
        #expect(effects.contains(.startMessageStream))
    }

    @Test("latest Maker recovery restores every persisted terminal state without a pet ID")
    func latestTerminalSessionRestoresAfterRestart() throws {
        for (rawStatus, expectedState) in [
            ("failed", GenerationSessionState.failed),
            ("canceled", .cancelled),
            ("completed", .succeeded),
        ] {
            let data = Data(#"""
            {
              "found":true,
              "job_id":"job_\#(rawStatus)",
              "status":"\#(rawStatus)",
              "result_pet_id":null,
              "operation":"create",
              "form":{"description":"Recovered \#(rawStatus)","style":"像素","quality":"standard","reference_images":[]},
              "message_revision":"9",
              "messages":[{"id":"msg_\#(rawStatus)","role":"assistant","kind":"generation_\#(rawStatus)","content":"terminal","progress":1,"created_at":"2026-07-22T00:00:00Z"}]
            }
            """#.utf8)

            let snapshot = try JSONDecoder().decode(
                LatestGenerationSessionSnapshot.self,
                from: data
            )
            let restore = try #require(GenerationSessionRestore(snapshot: snapshot))

            #expect(restore.state == expectedState)
            #expect(restore.jobID == "job_\(rawStatus)")
            #expect(restore.resultPetID == nil)
            #expect(restore.submittedForm?.description == "Recovered \(rawStatus)")
            #expect(restore.messageRevision == "9")
            #expect(restore.progress == 1)
        }
    }

    @Test("an empty latest Maker response cannot create a phantom session")
    func emptyLatestSessionDoesNotRestore() throws {
        let snapshot = try JSONDecoder().decode(
            LatestGenerationSessionSnapshot.self,
            from: Data(#"{"found":false,"messages":[]}"#.utf8)
        )

        #expect(GenerationSessionRestore(snapshot: snapshot) == nil)
    }

    @Test("recovery projections decode a bounded reference reselection count compatibly")
    func recoveryReferenceReselectionCountIsBoundedAndCompatible() throws {
        let latest = try JSONDecoder().decode(
            LatestGenerationSessionSnapshot.self,
            from: Data(#"{"found":true,"job_id":"job_refs","status":"failed","form":{"description":"Retry","style":"像素","quality":"standard","reference_images":[]},"reference_reselection_count":2,"messages":[]}"#.utf8)
        )
        let history = try JSONDecoder().decode(
            GenerationHistory.self,
            from: Data(#"{"found":true,"pet_id":"pet_refs","reference_reselection_count":2,"form":{"description":"Retry","style":"像素","quality":"standard","reference_images":[]},"messages":[]}"#.utf8)
        )
        let active = try JSONDecoder().decode(
            ActiveGenerationSnapshot.self,
            from: Data(#"{"job_id":"job_refs","status":"waiting_for_user","form":{"description":"Retry","style":"像素","quality":"standard","reference_images":[]},"heartbeat_at":"2026-07-22T00:00:00Z","message_revision":"1","reference_reselection_count":2,"messages":[]}"#.utf8)
        )
        let legacyLatest = try JSONDecoder().decode(
            LatestGenerationSessionSnapshot.self,
            from: Data(#"{"found":false,"messages":[]}"#.utf8)
        )

        #expect(latest.referenceReselectionCount == 2)
        #expect(try #require(GenerationSessionRestore(snapshot: latest))
            .referenceReselectionCount == 2)
        #expect(history.referenceReselectionCount == 2)
        #expect(active.referenceReselectionCount == 2)
        #expect(GenerationSessionRestore(snapshot: active).referenceReselectionCount == 2)
        #expect(legacyLatest.referenceReselectionCount == 0)

        for malformed in [
            #"{"found":false,"reference_reselection_count":-1,"messages":[]}"#,
            #"{"found":false,"reference_reselection_count":5,"messages":[]}"#,
            #"{"found":true,"job_id":"job_refs","status":"failed","form":{"description":"Retry","style":"像素","quality":"standard","reference_images":["/private/tmp/original.png"]},"reference_reselection_count":1,"messages":[]}"#,
        ] {
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(
                    LatestGenerationSessionSnapshot.self,
                    from: Data(malformed.utf8)
                )
            }
        }
    }

    @Test("daemon active_generation decodes into a resumable waiting session")
    func daemonActiveGenerationSnapshotDecodes() throws {
        let data = Data(#"""
        {
          "job_id":"job_snapshot",
          "status":"waiting_for_user",
          "form":{"description":"Snapshot prompt","style":"半写实","quality":"low","reference_images":[]},
          "session_id":"session_snapshot",
          "result_pet_id":"pet_existing",
          "operation":"modify",
          "baseline_revision_id":"rev_11111111111111111111111111111111",
          "owner_instance_id":"instance_old",
          "heartbeat_at":"2026-07-10T00:00:00Z",
          "message_revision":"11",
          "messages":[{"id":"msg_snapshot","job_id":"job_snapshot","sequence":11,"role":"assistant","kind":"input_request","content":"Choose a color","progress":0.3,"created_at":"2026-07-10T00:00:00Z"}],
          "input_request":{"id":"msg_snapshot","job_id":"job_snapshot","sequence":11,"role":"assistant","kind":"input_request","content":"Choose a color","progress":0.3,"created_at":"2026-07-10T00:00:00Z"}
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(ActiveGenerationSnapshot.self, from: data)
        let restore = GenerationSessionRestore(snapshot: snapshot)

        #expect(snapshot.status == .waitingForUser)
        #expect(snapshot.ownerInstanceID == "instance_old")
        #expect(restore.state == .waitingForInput)
        #expect(restore.jobID == "job_snapshot")
        #expect(restore.submittedForm?.description == "Snapshot prompt")
        #expect(restore.messages.map(\.id) == ["msg_snapshot"])
        #expect(restore.messageRevision == "11")
        #expect(restore.operation == .modify)
        #expect(restore.resultPetID == "pet_existing")
        #expect(restore.baselineRevisionID == "rev_11111111111111111111111111111111")
    }

    @Test("daemon active_generation decodes a recoverable failed session")
    func daemonRecoverableFailureSnapshotDecodes() throws {
        let data = Data(#"""
        {
          "job_id":"job_recoverable",
          "status":"failed",
          "form":{"description":"Preserved pet","style":"半写实","quality":"standard","reference_images":[]},
          "heartbeat_at":"2026-08-09T03:54:42Z",
          "recoverable":true,
          "failure_code":"generation_failed",
          "pause_reason":"checkpoint paused",
          "message_revision":"156",
          "messages":[]
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(ActiveGenerationSnapshot.self, from: data)
        let restore = GenerationSessionRestore(snapshot: snapshot)

        #expect(snapshot.status == .failed)
        #expect(restore.state == .recoverableFailed)
        #expect(restore.recoverable)
        #expect(restore.pauseReason == "checkpoint paused")
        #expect(restore.messageRevision == "156")
    }

    @Test("an edit session preserves its target across start, failure, and retry setup")
    func editSessionPreservesTargetIdentity() {
        var session = GenerationSession()
        let submitted = form(description: "Modify the existing pet")

        _ = session.reduce(.editRequested(
            form: submitted,
            initialMessage: message(id: "msg_edit", progress: 0.01),
            petID: "pet_existing",
            baselineRevisionID: "rev_11111111111111111111111111111111"
        ))
        _ = session.reduce(.startAccepted(jobID: "job_edit"))
        _ = session.reduce(.messagesReceived(
            [message(id: "msg_failed", kind: "generation_failed", progress: 1)],
            revision: "2"
        ))

        #expect(session.state == .failed)
        #expect(session.operation == .modify)
        #expect(session.resultPetID == "pet_existing")
        #expect(session.baselineRevisionID == "rev_11111111111111111111111111111111")
        #expect(session.canRetry)

        _ = session.reduce(.retryRequested(
            form: submitted,
            initialMessage: message(id: "msg_retry", progress: 0.01)
        ))
        #expect(session.state == .starting)
        #expect(session.jobID == "job_edit")
        #expect(session.operation == .modify)
        #expect(session.resultPetID == "pet_existing")
        #expect(session.baselineRevisionID == "rev_11111111111111111111111111111111")

        _ = session.reduce(.startFailed(message: message(
            id: "msg_retry_failed",
            kind: "generation_failed",
            progress: 1
        )))
        #expect(session.state == .failed)
        #expect(session.jobID == "job_edit")
        #expect(session.baselineRevisionID == "rev_11111111111111111111111111111111")
        #expect(session.canRetry)
    }

    @Test("resuming a failed job preserves its job and complete message history")
    func resumePreservesJobAndMessages() {
        var session = GenerationSession()
        let submitted = form(description: "Resume me")
        _ = session.reduce(.startRequested(
            form: submitted,
            initialMessage: message(id: "msg_user", progress: 0.01)
        ))
        _ = session.reduce(.startAccepted(jobID: "job_resume"))
        let failedMessages = [
            message(id: "msg_user", progress: 0.01),
            message(id: "msg_checkpoint", kind: "generation_checkpoint", progress: 0.13),
            message(id: "msg_failed", kind: "generation_failed", progress: 1),
        ]
        _ = session.reduce(.messagesReceived(failedMessages, revision: "3"))
        _ = session.reduce(.restore(GenerationSessionRestore(
            state: .recoverableFailed,
            jobID: "job_resume",
            submittedForm: submitted,
            messages: failedMessages,
            progress: 0.13,
            messageRevision: "3",
            recoverable: true,
            failureCode: "checkpoint_stalled",
            pauseReason: "The last verified checkpoint is retained.",
            capabilities: GenerationSessionCapabilities(
                canResume: true,
                canCancel: true
            )
        )))

        #expect(session.canResume)
        _ = session.reduce(.resumeRequested)
        #expect(session.state == .starting)
        #expect(session.jobID == "job_resume")
        #expect(session.messages == failedMessages)
        #expect(session.messageRevision == "3")

        let effects = session.reduce(.startAccepted(jobID: "job_resume"))
        #expect(session.state == .running)
        #expect(effects.contains(.startMessageStream))
    }

    @Test("typed runtime activity drives stages even while numeric progress stays low")
    func typedRuntimeActivityDrivesStages() {
        let generating = [
            message(id: "msg_generate", kind: "generation_activity_generating", progress: 0.11),
        ]
        let validating = [
            message(id: "msg_validate", kind: "generation_activity_validating", progress: 0.14),
        ]
        let importing = [
            message(id: "msg_import", kind: "generation_activity_importing", progress: 0.90),
        ]

        #expect(GenerationConversation.activeStepIndex(
            messages: generating,
            progress: 0.11,
            operation: .create
        ) == 1)
        #expect(GenerationConversation.activeStepIndex(
            messages: validating,
            progress: 0.14,
            operation: .create
        ) == 2)
        #expect(GenerationConversation.activeStepIndex(
            messages: importing,
            progress: 0.90,
            operation: .create
        ) == 3)
        #expect(GenerationConversation.activeStepIndex(
            messages: generating,
            progress: 0.11,
            operation: .modify
        ) == 2)
        #expect(GenerationConversation.checkpointCount([
            message(id: "checkpoint-1", kind: "generation_checkpoint", progress: 0.13),
            message(id: "heartbeat", kind: "generation_heartbeat", progress: 0.13),
            message(id: "checkpoint-2", kind: "generation_checkpoint", progress: 0.13),
        ]) == 2)
    }

    @Test("reconciling the same active snapshot does not restart its stream")
    func repeatedSnapshotDoesNotRestartStream() {
        let restore = GenerationSessionRestore(
            state: .running,
            jobID: "job_same",
            submittedForm: form(description: "Same job"),
            messages: [message(id: "msg_same", progress: 0.4)],
            progress: 0.4,
            messageRevision: "4"
        )
        var session = GenerationSession()

        let first = session.reduce(.restore(restore))
        let second = session.reduce(.restore(restore))

        #expect(first.contains(.startMessageStream))
        #expect(!second.contains(.startMessageStream))
        #expect(!second.contains(.stopMessageStream))
    }

    @Test("a submitted form cannot be replaced while the session is active")
    func activeFormIsImmutable() {
        var session = GenerationSession()
        let first = form(description: "Original submitted prompt")
        let replacement = form(description: "Edited draft must not leak")

        _ = session.reduce(.startRequested(
            form: first,
            initialMessage: message(id: "msg_first", progress: 0.05)
        ))
        _ = session.reduce(.startRequested(
            form: replacement,
            initialMessage: message(id: "msg_second", progress: 0.05)
        ))

        #expect(session.state == .starting)
        #expect(session.submittedForm == first)
        #expect(session.messages.map(\.id) == ["msg_first"])
    }

    @Test("waiting sessions can be cancelled")
    func waitingCanCancel() {
        var session = runningSession()
        _ = session.reduce(.messagesReceived(
            [message(id: "msg_wait", kind: "input_request", progress: 0.20)],
            revision: "2"
        ))

        #expect(session.canCancel)
        _ = session.reduce(.cancelRequested)

        #expect(session.state == .cancelling)
        #expect(session.isActive)
    }

    @Test("generation messages retain daemon IDs across repeated decoding")
    func messageIdentityIsStable() throws {
        let withID = Data(#"{"id":"msg_stable","role":"assistant","content":"same","progress":0.5,"created_at":"2026-07-10T00:00:00Z"}"#.utf8)
        let legacy = Data(#"{"role":"assistant","content":"legacy","progress":0.5,"created_at":"2026-07-10T00:00:00Z"}"#.utf8)

        let first = try JSONDecoder().decode(GenerationMessage.self, from: withID)
        let second = try JSONDecoder().decode(GenerationMessage.self, from: withID)
        let legacyFirst = try JSONDecoder().decode(GenerationMessage.self, from: legacy)
        let legacySecond = try JSONDecoder().decode(GenerationMessage.self, from: legacy)

        #expect(first.id == "msg_stable")
        #expect(second.id == first.id)
        #expect(legacyFirst.id == legacySecond.id)
        #expect(legacyFirst.id.hasPrefix("msg_legacy_"))
    }

    @Test("localized message copy never infers a terminal generation state")
    func terminalInferenceRequiresTypedKinds() {
        let localizedOnly = [
            GenerationMessage(
                role: "assistant",
                content: "完成，可在宠物库启用。",
                progress: 1,
                createdAt: "2026-07-10T00:00:00Z"
            ),
        ]
        let renamedCopyOnly = [
            GenerationMessage(
                role: "assistant",
                content: "Finished and ready to use.",
                progress: 1,
                createdAt: "2026-07-10T00:00:00Z"
            ),
        ]

        for messages in [localizedOnly, renamedCopyOnly] {
            #expect(!GenerationConversation.succeeded(messages))
            #expect(!GenerationConversation.cancelled(messages))
            #expect(!GenerationConversation.failed(messages))
            #expect(!GenerationConversation.terminalUnsuccessful(messages))
        }
    }

    @Test("cancellation preserves the last real generation stage")
    func cancellationPreservesTheLastRealStage() {
        let canceledDuringBrief = [
            message(id: "msg_brief", kind: "generation_progress", progress: 0.10),
            message(id: "msg_cancelled", kind: "generation_canceled", progress: 1),
        ]
        let canceledDuringGeneration = [
            message(id: "msg_generation", kind: "generation_progress", progress: 0.40),
            message(id: "msg_cancelled_later", kind: "generation_canceled", progress: 1),
        ]

        #expect(GenerationConversation.activeStepIndex(
            messages: canceledDuringBrief,
            progress: 1
        ) == 0)
        #expect(GenerationConversation.activeStepIndex(
            messages: canceledDuringGeneration,
            progress: 1
        ) == 1)
    }

    @Test("generation history decodes terminal status into a typed bounded value")
    func generationHistoryStatusIsTyped() throws {
        for (rawStatus, expected) in [
            ("completed", GenerationJobHistoryStatus.completed),
            ("cancelled", GenerationJobHistoryStatus.canceled),
            ("failed", GenerationJobHistoryStatus.failed),
        ] {
            let data = Data(
                "{\"found\":true,\"pet_id\":\"pet_fixture\",\"status\":\"\(rawStatus)\"}"
                    .utf8
            )
            let history = try JSONDecoder().decode(GenerationHistory.self, from: data)
            #expect(history.status == expected)
        }

        let unknown = try JSONDecoder().decode(
            GenerationHistory.self,
            from: Data(
                #"{"found":true,"pet_id":"pet_fixture","status":"future_status"}"#.utf8
            )
        )
        #expect(unknown.status == nil)
    }

    @Test("a terminal job requests stream shutdown exactly once")
    func terminalJobStopsStreamOnce() {
        var session = runningSession()
        let completed = [message(id: "msg_done", kind: "generation_completed", progress: 1)]

        let firstEffects = session.reduce(.messagesReceived(completed, revision: "3"))
        let secondEffects = session.reduce(.messagesReceived(completed, revision: "3"))

        #expect(session.state == .succeeded)
        #expect(firstEffects.contains(.stopMessageStream))
        #expect(firstEffects.contains(.refreshSnapshot))
        #expect(!secondEffects.contains(.stopMessageStream))
        #expect(!secondEffects.contains(.refreshSnapshot))
        #expect(!session.canSendReply)
        #expect(!GenerationConversation.canSendReply(completed))
    }

    @Test("typed terminal metadata restores the real pet and revision independently")
    func terminalMetadataRestoresWithoutConfusingPetAndRevisionIDs() throws {
        let data = Data(#"""
        {
          "found":true,
          "pet_id":"pet_created",
          "job_id":"job_created",
          "status":"completed",
          "result_pet_id":"pet_created",
          "revision_id":"rev_0123456789abcdef0123456789abcdef",
          "validation_summary":{"ok":true,"state_count":9,"frame_count":120,"warning_count":0},
          "messages":[]
        }
        """#.utf8)
        let history = try JSONDecoder().decode(GenerationHistory.self, from: data)
        let restore = GenerationSessionRestore(
            state: .succeeded,
            jobID: try #require(history.jobId),
            submittedForm: history.form,
            messages: history.messages,
            progress: 1,
            messageRevision: "",
            resultPetID: history.resultPetId,
            resultRevisionID: history.revisionId,
            validationSummary: history.validationSummary
        )
        var session = GenerationSession()

        _ = session.reduce(.restore(restore))

        #expect(session.resultPetID == "pet_created")
        #expect(session.resultRevisionID == "rev_0123456789abcdef0123456789abcdef")
        #expect(session.resultPetID != session.resultRevisionID)
        #expect(session.validationSummary?.stateCount == 9)
        #expect(session.validationSummary?.frameCount == 120)
        #expect(!session.canSendReply)
    }

    @Test("a create session accepts typed result metadata when the terminal wait response arrives")
    func createSessionAcceptsTerminalResultMetadata() {
        var session = runningSession()
        _ = session.reduce(.messagesReceived(
            [message(id: "msg_done", kind: "generation_completed", progress: 1)],
            revision: "3"
        ))

        _ = session.reduce(.resultMetadataReceived(GenerationResultMetadata(
            resultPetID: "pet_result",
            revisionID: "rev_0123456789abcdef0123456789abcdef",
            validationSummary: GenerationValidationSummary(
                ok: true,
                stateCount: 7,
                frameCount: 120,
                warningCount: 0
            )
        )))

        #expect(session.state == .succeeded)
        #expect(session.resultPetID == "pet_result")
        #expect(session.resultRevisionID == "rev_0123456789abcdef0123456789abcdef")
        #expect(session.validationSummary?.ok == true)
    }

    @Test("a structured reply explicitly reactivates a waiting session")
    func replyReactivatesWaitingSession() {
        var session = runningSession()
        _ = session.reduce(.messagesReceived(
            [message(id: "msg_question", kind: "input_request", progress: 0.25)],
            revision: "2"
        ))

        _ = session.reduce(.replySubmitted)

        #expect(session.state == .running)
        #expect(session.isActive)
        #expect(!session.canSendReply)
        #expect(session.canCancel)
    }

    @Test("generation states are exhaustive and only lifecycle work is active")
    func stateCasesAndActivityAreStrict() {
        #expect(GenerationSessionState.allCases == [
            .idle,
            .starting,
            .running,
            .waitingForInput,
            .paused,
            .recoverableFailed,
            .cancelling,
            .cancelCleanup,
            .succeeded,
            .failed,
            .cancelled,
        ])
        #expect(!GenerationSessionState.idle.isActive)
        #expect(GenerationSessionState.starting.isActive)
        #expect(GenerationSessionState.running.isActive)
        #expect(GenerationSessionState.waitingForInput.isActive)
        #expect(GenerationSessionState.paused.isActive)
        #expect(GenerationSessionState.recoverableFailed.isActive)
        #expect(GenerationSessionState.cancelling.isActive)
        #expect(GenerationSessionState.cancelCleanup.isActive)
        #expect(!GenerationSessionState.succeeded.isActive)
        #expect(!GenerationSessionState.failed.isActive)
        #expect(!GenerationSessionState.cancelled.isActive)
    }

    private func runningSession() -> GenerationSession {
        var session = GenerationSession()
        _ = session.reduce(.startRequested(
            form: form(description: "Submitted"),
            initialMessage: message(id: "msg_user", progress: 0.05)
        ))
        _ = session.reduce(.startAccepted(jobID: "job_active"))
        return session
    }

    private func form(description: String) -> GenerationForm {
        GenerationForm(
            description: description,
            style: "半写实",
            quality: .low,
            referenceImages: ["/tmp/reference.png"]
        )
    }

    private func message(
        id: String,
        kind: String? = nil,
        progress: Double
    ) -> GenerationMessage {
        GenerationMessage(
            id: id,
            role: "assistant",
            content: kind ?? "working",
            progress: progress,
            createdAt: "2026-07-10T00:00:00Z",
            kind: kind
        )
    }
}
