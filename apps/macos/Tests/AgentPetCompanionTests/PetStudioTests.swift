import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct PetStudioTests {
    @Test
    func briefKeepsTheSixSupportedStylesAndFourRenderContracts() {
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
            RenderSize(width: 768, height: 832),
            RenderSize(width: 1536, height: 1664),
        ])
    }

    @Test
    func timingSummaryUsesTheClosedAuthoredContractInBothLocales() {
        let durations = PetAnimationContract.defaultStateDurationsMS

        #expect(PetStudioPresentation.timingSummary(
            nativeFPS: 20,
            stateDurationsMS: durations,
            localeIdentifier: "en"
        ) == "20 FPS · 1 s: start · done   2 s: idle · tool · waiting · review · failed")
        #expect(PetStudioPresentation.stateDurationSummary(
            durations,
            localeIdentifier: "zh-Hans"
        ) == "1 秒：start · done   2 秒：idle · tool · waiting · review · failed")
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
            at: 3,
            activeIndex: 3,
            sessionState: .succeeded
        ) == .complete)
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

        #expect(PetStudioPresentation.isProgressMessage(progress))
        #expect(PetStudioPresentation.isProgressMessage(legacyStarted))
        #expect(!PetStudioPresentation.isProgressMessage(ordinary))
        #expect(!PetStudioPresentation.isProgressMessage(misleadingUnknown))
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
