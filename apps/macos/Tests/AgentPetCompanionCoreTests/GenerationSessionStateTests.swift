import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct GenerationSessionStateTests {
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

    @Test("daemon active_generation decodes into a resumable waiting session")
    func daemonActiveGenerationSnapshotDecodes() throws {
        let data = Data(#"""
        {
          "job_id":"job_snapshot",
          "status":"waiting_for_user",
          "form":{"description":"Snapshot prompt","style":"半写实","quality":"high","reference_images":[]},
          "session_id":"session_snapshot",
          "result_pet_id":null,
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
            .cancelling,
            .succeeded,
            .failed,
            .cancelled,
        ])
        #expect(!GenerationSessionState.idle.isActive)
        #expect(GenerationSessionState.starting.isActive)
        #expect(GenerationSessionState.running.isActive)
        #expect(GenerationSessionState.waitingForInput.isActive)
        #expect(GenerationSessionState.cancelling.isActive)
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
            quality: .high,
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
