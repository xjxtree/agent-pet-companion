import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Maker session workspace")
struct MakerSessionWorkspaceTests {
    @Test
    func unfinishedPolicyCoversWaitingRecoveryAndCancellationCleanup() throws {
        let decoder = JSONDecoder()
        let waiting = try decoder.decode(
            GenerationStudioHistoryRecord.self,
            from: Self.recordJSON(
                jobID: "job_waiting",
                status: "waiting_for_user",
                recoverable: false,
                cancellationPending: false,
                capabilities: #"{"can_reply":true,"can_resume":false,"can_cancel":true,"can_open_result":false,"can_open_session":false,"can_delete":false}"#
            )
        )
        let recoverable = try decoder.decode(
            GenerationStudioHistoryRecord.self,
            from: Self.recordJSON(
                jobID: "job_recoverable",
                status: "failed",
                recoverable: true,
                cancellationPending: false,
                capabilities: #"{"can_reply":false,"can_resume":true,"can_cancel":true,"can_open_result":false,"can_open_session":false,"can_delete":false}"#
            )
        )
        let cancelCleanup = try decoder.decode(
            GenerationStudioHistoryRecord.self,
            from: Self.recordJSON(
                jobID: "job_cancel_cleanup",
                status: "running",
                recoverable: false,
                cancellationPending: true,
                capabilities: #"{"can_reply":false,"can_resume":false,"can_cancel":false,"can_open_result":false,"can_open_session":false,"can_delete":false}"#
            )
        )
        let canceled = try decoder.decode(
            GenerationStudioHistoryRecord.self,
            from: Self.recordJSON(
                jobID: "job_canceled",
                status: "canceled",
                recoverable: false,
                cancellationPending: false,
                capabilities: #"{"can_reply":false,"can_resume":false,"can_cancel":false,"can_open_result":false,"can_open_session":false,"can_delete":true}"#
            )
        )

        #expect(MakerSessionPolicy.isUnfinished(waiting))
        #expect(MakerSessionPolicy.isUnfinished(recoverable))
        #expect(MakerSessionPolicy.isUnfinished(cancelCleanup))
        #expect(!MakerSessionPolicy.isUnfinished(canceled))
        #expect(canceled.capabilities?.canResume == false)
        #expect(canceled.capabilities?.canOpenSession == false)
    }

    @Test
    func everySessionStateMapsToOneUnifiedSummaryKind() {
        #expect(MakerSessionPolicy.summaryKind(
            status: .pending,
            recoverable: false,
            cancellationPending: false
        ) == .pending)
        #expect(MakerSessionPolicy.summaryKind(
            status: .running,
            recoverable: false,
            cancellationPending: false
        ) == .running)
        #expect(MakerSessionPolicy.summaryKind(
            status: .waitingForUser,
            recoverable: false,
            cancellationPending: false
        ) == .waitingForUser)
        #expect(MakerSessionPolicy.summaryKind(
            status: .completed,
            recoverable: false,
            cancellationPending: false
        ) == .completed)
        #expect(MakerSessionPolicy.summaryKind(
            status: .failed,
            recoverable: true,
            cancellationPending: false
        ) == .recoverableFailure)
        #expect(MakerSessionPolicy.summaryKind(
            status: .failed,
            recoverable: false,
            cancellationPending: false
        ) == .failed)
        #expect(MakerSessionPolicy.summaryKind(
            status: .canceled,
            recoverable: false,
            cancellationPending: false
        ) == .canceled)
        #expect(MakerSessionPolicy.summaryKind(
            status: .running,
            recoverable: false,
            cancellationPending: true
        ) == .cancellationPending)
        #expect(MakerSessionPolicy.summaryKind(
            status: nil,
            recoverable: nil,
            cancellationPending: nil
        ) == .unknown)
    }

    @Test
    func backendEndTimeFreezesAConversationLongerThanSixHours() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-09T20:00:00Z"))
        #expect(MakerSessionClock.duration(
            startedAt: "2026-08-08T00:00:00Z",
            endedAt: nil,
            now: now
        ) == "44:00:00")
        #expect(MakerSessionClock.duration(
            startedAt: "2026-08-08T00:00:00Z",
            endedAt: "2026-08-08T06:01:00Z",
            now: now
        ) == "06:01:00")
    }

    @Test
    func splitViewKeepsDraftConversationPaginationAndNoHistorySheetDependency() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let source = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion/Views/MakerSessionWorkspace.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        #expect(text.contains("HSplitView"))
        #expect(text.contains("LayoutPreservingHorizontalSeparatorGap()"))
        #expect(text.contains("MakerSplitDividerAnchorKey"))
        #expect(text.contains(".overlayPreferenceValue(MakerSplitDividerAnchorKey.self)"))
        #expect(text.contains(".allowsHitTesting(false)"))
        #expect(text.contains("frame(minWidth: 260, idealWidth: 320, maxWidth: 400)"))
        #expect(text.contains("frame(minWidth: 500"))
        #expect(text.contains("MakerWorkspaceHeader"))
        #expect(text.contains("ProductPageHeader"))
        #expect(text.contains("studioWorkspacePageSubtitle"))
        #expect(text.contains("studioWorkspaceHistoryCountFormat"))
        #expect(text.contains("studioWorkspaceRecent"))
        #expect(text.contains(".buttonStyle(.borderedProminent)"))
        #expect(text.contains(".makerWorkspacePaneSurface()"))
        #expect(text.contains(".padding(16)"))
        #expect(text.contains(".scrollContentBackground(.hidden)"))
        #expect(text.contains(".background(.bar, ignoresSafeAreaEdges: .all)"))
        #expect(!text.contains(".background(Color(nsColor: .controlBackgroundColor))"))
        #expect(text.contains(".makerSessionListRowChrome()"))
        #expect(text.contains(".listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))"))
        #expect(text.contains(".listRowSeparator(.hidden)"))
        #expect(text.contains("maker.session-list.new"))
        #expect(text.contains("maker.draft.submit"))
        #expect(text.contains("maker.draft.discard"))
        #expect(text.contains("loadOlderGenerationHistoryMessages"))
        #expect(text.contains("hasUnseenMessages"))
        #expect(text.contains("MakerSessionStatusPanel(detail: detail)"))
        #expect(text.contains("maker.session-status-panel"))
        #expect(text.contains("MakerSessionSummaryKind"))
        #expect(text.contains("Color(nsColor: .controlBackgroundColor)"))
        #expect(text.contains(".clipShape(previewShape)"))
        #expect(text.contains("private var inlineComposer: some View"))
        #expect(text.contains("copySelectedGenerationHistoryBriefToNewDraft"))
        #expect(!text.contains("safeAreaInset(edge: .top"))
        #expect(text.contains("safeAreaInset(edge: .bottom"))
        #expect(text.contains("MakerConversationActionBar("))
        #expect(!text.contains("MakerConversationHeader"))
        #expect(text.contains("maker.session-action-bar"))
        #expect(text.contains("ViewThatFits(in: .horizontal)"))
        #expect(text.contains("MakerConversationActions("))
        #expect(text.contains(".menuStyle(.borderlessButton)"))
        #expect(text.contains("maker.session-timeline-scroll"))
        #expect(text.contains("maker.session-composer"))
        #expect(text.contains("maker.session.continue"))
        #expect(text.contains("studioWorkspaceNonResumableFailureHint"))
        #expect(!text.contains("GenerationHistorySheet("))
    }

    @Test
    func notificationsRouteByExactJobAndSuppressAnAlreadyOpenTask() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let macOSRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let coordinator = try String(
            contentsOf: macOSRoot.appendingPathComponent(
                "Sources/AgentPetCompanion/App/MakerNotificationCoordinator.swift"
            ),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: macOSRoot.appendingPathComponent(
                "Sources/AgentPetCompanion/App/AppStore.swift"
            ),
            encoding: .utf8
        )

        #expect(coordinator.contains(#"content.userInfo = ["generation_job_id": jobID]"#))
        #expect(coordinator.contains("self?.route?(jobID)"))
        #expect(coordinator.contains("try? await center.requestAuthorization"))
        #expect(!coordinator.contains("requestAuthorization(options: [.alert, .sound]) {"))
        #expect(store.contains("NSApp.isActive"))
        #expect(store.contains("selectedGenerationHistoryJobID == jobID"))
        #expect(!store.contains("case .running:\n            ("))
    }

    private static func recordJSON(
        jobID: String,
        status: String,
        recoverable: Bool,
        cancellationPending: Bool,
        capabilities: String
    ) -> Data {
        Data(
            """
            {
              "job_id":"\(jobID)",
              "status":"\(status)",
              "operation":"create",
              "visible_title":"Test pet",
              "brief_preview":"Test pet",
              "style":"pixel",
              "quality":"standard",
              "reference_count":0,
              "result_pet_id":null,
              "retry_of_job_id":null,
              "created_at":"2026-08-08T00:00:00Z",
              "updated_at":"2026-08-08T00:01:00Z",
              "started_at":"2026-08-08T00:00:00Z",
              "ended_at":null,
              "progress":0.4,
              "recoverable":\(recoverable),
              "pause_reason":null,
              "cancellation_pending":\(cancellationPending),
              "capabilities":\(capabilities)
            }
            """.utf8
        )
    }
}
