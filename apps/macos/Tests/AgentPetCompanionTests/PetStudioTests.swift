import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct PetStudioTests {
    @Test
    func briefKeepsTwoStudioChoicesWhileTheRuntimeDecodesThreeRenderTiers() throws {
        #expect(StylePreset.allCases == [
            .realistic,
            .semiRealistic,
            .modern,
            .pixel,
            .anime,
            .unspecified,
        ])
        #expect(QualityLevel.allCases.map(\.renderSize) == [
            RenderSize(width: 192, height: 208),
            RenderSize(width: 384, height: 416),
            RenderSize(width: 576, height: 624),
        ])
        #expect(QualityLevel.studioCases == [.low, .standard])
        #expect(try JSONDecoder().decode(
            QualityLevel.self,
            from: Data(#""high""#.utf8)
        ) == .high)
    }

    @Test
    func timingSummaryUsesTheClosedAuthoredContractInBothLocales() {
        let states = PetAnimationContract.defaultStates

        #expect(PetStudioPresentation.timingSummary(
            states,
            localeIdentifier: "en"
        ) == "50 frames across 9 actions · authored per-frame timing")
        #expect(PetStudioPresentation.timingSummary(
            states,
            localeIdentifier: "zh-Hans"
        ) == "50 帧 · 9 个动作 · 逐帧创作时序")
    }

    @Test
    func generationStagesExposeStateWithoutInventingAPercentage() {
        #expect(PetStudioPresentation.stageState(
            at: 0,
            activeIndex: 0,
            sessionState: .running
        ) == .current)
        #expect(PetStudioPresentation.stageState(
            at: 0,
            activeIndex: 2,
            sessionState: .running
        ) == .complete)
        #expect(PetStudioPresentation.stageState(
            at: 2,
            activeIndex: 2,
            sessionState: .failed
        ) == .failed)
        #expect(PetStudioPresentation.stageState(
            at: 0,
            activeIndex: 0,
            sessionState: .cancelled
        ) == .cancelled)
        #expect(PetStudioPresentation.stageState(
            at: 3,
            activeIndex: 3,
            sessionState: .succeeded
        ) == .complete)
        #expect(PetStudioPresentation.stageState(
            at: 1,
            activeIndex: 0,
            sessionState: .failed,
            hasRecordedRuntimePhase: false
        ) == .unrecorded)
    }

    @Test
    func onlyModifySessionsUseTheBaselineWorkspace() {
        #expect(!PetStudioPresentation.showsModificationWorkspace(for: GenerationSession()))
        #expect(PetStudioPresentation.showsModificationWorkspace(for: GenerationSession(
            state: .running,
            operation: .modify,
            resultPetID: "pet_example"
        )))
        #expect(!PetStudioPresentation.showsModificationWorkspace(for: GenerationSession(
            state: .running,
            operation: .create
        )))
    }

    @Test
    func completedProtocolStateDistinguishesIncompleteHistoryFromARealResult() {
        let incomplete = GenerationSession(
            state: .succeeded,
            jobID: "job_legacy_completed",
            submittedForm: GenerationForm(
                description: "Completed without a retained result",
                style: StylePreset.pixel.rawValue,
                quality: .standard,
                referenceImages: []
            ),
            resultPetID: nil,
            resultRevisionID: "rev_must_not_be_presented_without_a_pet",
            validationSummary: GenerationValidationSummary(
                ok: true,
                stateCount: 7,
                frameCount: 120,
                warningCount: 0
            )
        )
        let complete = GenerationSession(
            state: .succeeded,
            jobID: "job_completed",
            resultPetID: "pet_completed",
            resultRevisionID: "rev_completed"
        )

        #expect(incomplete.state == .succeeded)
        #expect(PetStudioPresentation.completedHistoryIsIncomplete(incomplete))
        #expect(!PetStudioPresentation.completedHistoryIsIncomplete(complete))
        #expect(APCLocalization.text(.studioIncompleteHistoryTitle, locale: "en")
            == "Completed Session History Is Incomplete")
        #expect(APCLocalization.text(.studioIncompleteHistoryDetail, locale: "zh-Hans")
            .contains("结果宠物不可用"))
    }

    @Test
    func waitingRestoresRequestComposerFocusButTerminalStatesDoNot() {
        #expect(PetStudioPresentation.shouldFocusComposer(onAppearFor: .waitingForInput))
        #expect(!PetStudioPresentation.shouldFocusComposer(onAppearFor: .running))
        #expect(!PetStudioPresentation.shouldFocusComposer(onAppearFor: .succeeded))
        #expect(!PetStudioPresentation.shouldFocusComposer(onAppearFor: .failed))
        #expect(!PetStudioPresentation.shouldFocusComposer(onAppearFor: .cancelled))
    }

    @Test
    func failedSessionUsesAVisibleReferenceReselectionActionBeforeRetry() {
        let retryable = GenerationSession(
            state: .failed,
            jobID: "job",
            submittedForm: GenerationForm(
                description: "Pet",
                style: "modern",
                quality: .standard,
                referenceImages: []
            )
        )
        #expect(PetMakerProductPresentation(
            session: retryable,
            resultPetAvailable: false,
            referenceReselectionCount: 0
        ).primaryAction == .retry)
        #expect(PetMakerProductPresentation(
            session: retryable,
            resultPetAvailable: false,
            referenceReselectionCount: 2
        ).primaryAction == .reselectReferences)
        #expect(PetMakerProductPresentation(
            session: retryable,
            resultPetAvailable: false,
            referenceReselectionCount: -1
        ).primaryAction == .retry)
        #expect(PetMakerProductPresentation(
            session: GenerationSession(state: .failed, jobID: "job"),
            resultPetAvailable: false,
            referenceReselectionCount: 2
        ).primaryAction == .unavailable)
    }

    @Test
    func exactHistoricalBaselineDoesNotFollowLaterHeadChanges() {
        let baselineID = "rev_11111111111111111111111111111111"
        let oldRevision = PetRevisionHistoryRecord(
            revisionID: baselineID,
            current: false,
            validated: true,
            coverPath: "/owned/old-cover.png"
        )
        let firstHistory = PetHistorySnapshot(
            petID: "pet_example",
            currentRevisionID: "rev_22222222222222222222222222222222",
            revisions: [
                PetRevisionHistoryRecord(
                    revisionID: "rev_22222222222222222222222222222222",
                    current: true,
                    validated: true,
                    coverPath: "/owned/current-a.png"
                ),
                oldRevision,
            ]
        )
        let laterHistory = PetHistorySnapshot(
            petID: "pet_example",
            currentRevisionID: "rev_33333333333333333333333333333333",
            revisions: [
                PetRevisionHistoryRecord(
                    revisionID: "rev_33333333333333333333333333333333",
                    current: true,
                    validated: true,
                    coverPath: "/owned/current-b.png"
                ),
                oldRevision,
            ]
        )

        #expect(PetStudioPresentation.validatedBaselineRevision(
            in: firstHistory,
            revisionID: baselineID
        )?.coverPath == "/owned/old-cover.png")
        #expect(PetStudioPresentation.validatedBaselineRevision(
            in: laterHistory,
            revisionID: baselineID
        )?.coverPath == "/owned/old-cover.png")
        #expect(PetStudioPresentation.validatedBaselineRevision(
            in: laterHistory,
            revisionID: "rev_44444444444444444444444444444444"
        ) == nil)
    }

    @Test
    func baselineTargetStateUsesTheStableContractInsteadOfTimelineKinds() {
        #expect(PetStudioPresentation.baselineTargetState(localeIdentifier: "en")
            == "Keep existing contract")
        #expect(PetStudioPresentation.baselineTargetState(localeIdentifier: "zh-Hans")
            == "保持现有合同")
    }

    @Test
    func terminalEventsUseStructuredNoticesInsteadOfConversationRows() {
        let visible = GenerationMessage(
            role: "assistant",
            content: "Working",
            progress: 0.4,
            createdAt: "",
            kind: "generation_progress"
        )
        let failure = GenerationMessage(
            role: "assistant",
            content: "Raw provider failure",
            progress: 1,
            createdAt: "",
            kind: "generation_failed"
        )

        #expect(PetStudioPresentation.timelineMessages([visible, failure]) == [visible])
    }

    @Test
    func codexConversationCombinesLiveDeltasAndStartsANewBubbleAfterUserInput() {
        let messages = [
            GenerationMessage(
                id: "user-1",
                role: "user",
                content: "Make a fox",
                progress: 0.01,
                createdAt: ""
            ),
            GenerationMessage(
                id: "progress",
                role: "assistant",
                content: "Starting",
                progress: 0.08,
                createdAt: "",
                kind: "generation_progress"
            ),
            GenerationMessage(
                id: "codex-1",
                role: "assistant",
                content: "I am ",
                progress: 0.11,
                createdAt: "",
                kind: "codex_message"
            ),
            GenerationMessage(
                id: "codex-2",
                role: "assistant",
                content: "building it.",
                progress: 0.11,
                createdAt: "",
                kind: "codex_message"
            ),
            GenerationMessage(
                id: "user-2",
                role: "user",
                content: "Keep the blue scarf",
                progress: 0.2,
                createdAt: ""
            ),
            GenerationMessage(
                id: "codex-3",
                role: "assistant",
                content: "Understood.",
                progress: 0.25,
                createdAt: "",
                kind: "codex_message"
            ),
        ]

        let entries = PetStudioPresentation.codexConversationEntries(messages)

        #expect(entries.count == 4)
        #expect(entries[0].role == .user)
        #expect(entries[1].role == .codex)
        #expect(entries[1].content == "I am building it.")
        #expect(entries[2].content == "Keep the blue scarf")
        #expect(entries[3].content == "Understood.")
        #expect(PetStudioPresentation.progressMessages(messages).map(\.id) == ["progress"])
    }

    @Test
    func onlyTypedRuntimeProgressKindsUseTheCompactProgressRow() {
        let progress = GenerationMessage(
            role: "assistant",
            content: "Rendering",
            progress: 0.4,
            createdAt: "",
            kind: "generation_progress"
        )
        let legacyStarted = GenerationMessage(
            role: "assistant",
            content: "Starting",
            progress: 0.1,
            createdAt: "",
            kind: "generation_started"
        )
        let ordinary = GenerationMessage(
            role: "assistant",
            content: "A detailed response",
            progress: 0.4,
            createdAt: "",
            kind: nil
        )
        let misleadingUnknown = GenerationMessage(
            role: "assistant",
            content: "Unknown event",
            progress: 0.4,
            createdAt: "",
            kind: "not_progress"
        )
        let activity = GenerationMessage(
            role: "assistant",
            content: "Generating",
            progress: 0.11,
            createdAt: "",
            kind: "generation_activity_generating"
        )
        let checkpoint = GenerationMessage(
            role: "assistant",
            content: "Continuing",
            progress: 0.13,
            createdAt: "",
            kind: "generation_checkpoint"
        )
        let heartbeat = GenerationMessage(
            role: "assistant",
            content: "Alive",
            progress: 0.13,
            createdAt: "",
            kind: "generation_heartbeat"
        )

        #expect(PetStudioPresentation.isProgressMessage(progress))
        #expect(PetStudioPresentation.isProgressMessage(legacyStarted))
        #expect(PetStudioPresentation.isProgressMessage(activity))
        #expect(PetStudioPresentation.isProgressMessage(checkpoint))
        #expect(!PetStudioPresentation.isProgressMessage(heartbeat))
        #expect(!PetStudioPresentation.isProgressMessage(ordinary))
        #expect(!PetStudioPresentation.isProgressMessage(misleadingUnknown))
    }

    @Test
    func legacyCheckpointLimitFailureIsNotPresentedAsAConnectionFailure() {
        let failure = GenerationMessage(
            role: "assistant",
            content: "external full source remained incomplete after 6 bounded checkpoint turns。请在 Agent 连接中修复 Codex App Server 后重试。",
            progress: 1,
            createdAt: "",
            kind: "generation_failed"
        )

        let chineseDetail = PetStudioPresentation.failureDetail(
            for: [failure],
            localeIdentifier: "zh-Hans"
        )
        let englishDetail = PetStudioPresentation.failureDetail(
            for: [failure],
            localeIdentifier: "en"
        )

        #expect(chineseDetail.contains("旧版固定续接次数上限"))
        #expect(chineseDetail.contains("并非 Codex App Server 连接故障"))
        #expect(chineseDetail.contains("继续制作"))
        #expect(!chineseDetail.contains("Agent 连接中修复"))
        #expect(englishDetail.contains("old fixed continuation limit"))
        #expect(englishDetail.contains("connection did not fail"))
        #expect(englishDetail.contains("Choose Continue"))
        #expect(!englishDetail.contains("Agent 连接中修复"))
    }

    @Test
    func failureNoticeShowsABoundedRedactedTypedSummaryAndRecovery() {
        let failure = GenerationMessage(
            role: "assistant",
            content: "Provider failed at /Users/example/private.petpack\nBearer secret-token",
            progress: 1,
            createdAt: "",
            kind: "generation_failed"
        )

        let detail = PetStudioPresentation.failureDetail(
            for: [failure],
            homeURL: URL(fileURLWithPath: "/Users/example"),
            maximumSummaryScalars: 40
        )

        #expect(detail.contains("<redacted-path>"))
        #expect(detail.contains("<redacted>"))
        #expect(!detail.contains("/Users/example"))
        #expect(!detail.contains("secret-token"))
        #expect(detail.contains(APCLocalization.text(.studioFailedDetail)))
    }

    @Test
    func untypedFailureCopyCannotBecomeTheFailureSummary() {
        let ordinary = GenerationMessage(
            role: "assistant",
            content: "generation failed in localized prose",
            progress: 1,
            createdAt: "",
            kind: nil
        )

        #expect(PetStudioPresentation.failureDetail(for: [ordinary])
            == APCLocalization.text(.studioFailedDetail))
    }
}
