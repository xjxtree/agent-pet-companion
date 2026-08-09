import AgentPetCompanionCore
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("AI Pet Maker experience presentation")
struct MakerExperiencePresentationTests {
    @Test
    func sourceKeepsDescribeSessionAndResultAsDistinctSurfaces() throws {
        let studioSource = try source("PetStudioView.swift")
        let workspaceSource = try source("MakerSessionWorkspace.swift")

        #expect(studioSource.contains("MakerSessionWorkspace()"))
        #expect(workspaceSource.contains("HSplitView"))
        #expect(workspaceSource.contains("MakerDraftContent()"))
        #expect(workspaceSource.contains("MakerConversationContent()"))
        #expect(workspaceSource.contains("MakerSessionStatusPanel(detail: detail)"))
        #expect(!workspaceSource.contains("MakerSessionComposer(detail: detail)"))
        #expect(workspaceSource.contains("maker.draft.submit"))
        #expect(workspaceSource.contains("maker.draft.discard"))
        #expect(workspaceSource.contains("maker.session-status-panel"))
        #expect(workspaceSource.contains("copySelectedGenerationHistoryBriefToNewDraft"))
        #expect(!workspaceSource.contains("GenerationHistorySheet("))
        #expect(!studioSource.contains("maker.layout.two-stage"))
    }

    @Test
    func layoutHasOneVisualCenterForEachProductPhase() {
        let idle = MakerExperiencePresentation(
            session: GenerationSession(),
            resultPetAvailable: false
        )
        let running = MakerExperiencePresentation(session: GenerationSession(
            state: .running,
            jobID: "job_running",
            submittedForm: form()
        ), resultPetAvailable: false)
        let modifying = MakerExperiencePresentation(session: GenerationSession(
            state: .waitingForInput,
            jobID: "job_edit",
            submittedForm: form(),
            operation: .modify,
            resultPetID: "pet_existing"
        ), resultPetAvailable: false)
        let result = MakerExperiencePresentation(session: GenerationSession(
            state: .succeeded,
            jobID: "job_done",
            submittedForm: form(),
            resultPetID: "pet_result",
            resultRevisionID: "rev_result"
        ), resultPetAvailable: true)

        #expect(idle.phase == .describe)
        #expect(idle.showsCenteredBrief)
        #expect(idle.primaryAction == .createPet)
        #expect(!idle.showsSession)
        #expect(!idle.showsBaselineInspector)
        #expect(!idle.showsResult)

        #expect(running.phase == .createTogether)
        #expect(!running.showsCenteredBrief)
        #expect(running.showsSession)
        #expect(running.primaryAction == .cancel)
        #expect(!running.showsBaselineInspector)

        #expect(modifying.showsSession)
        #expect(modifying.showsBaselineInspector)
        #expect(modifying.primaryAction == .sendReply)

        #expect(result.phase == .result)
        #expect(result.showsSession)
        #expect(result.showsResult)
        #expect(result.primaryAction == .usePet)
        #expect(result.secondaryActions == [.continueEditing])
        #expect(result.resultReadiness == .ready)

        let previewNeedsRepair = MakerExperiencePresentation(
            session: GenerationSession(
                state: .succeeded,
                jobID: "job_repair",
                resultPetID: "pet_repair",
                resultRevisionID: "rev_repair"
            ),
            resultPetAvailable: true,
            resultPreviewAvailable: false
        )
        #expect(previewNeedsRepair.resultReadiness == .previewNeedsRepair)
        #expect(previewNeedsRepair.resultReadiness.needsRecovery)
        #expect(previewNeedsRepair.primaryAction == .unavailable)

        let missingResult = MakerExperiencePresentation(
            session: GenerationSession(
                state: .succeeded,
                jobID: "job_missing",
                resultPetID: "pet_missing",
                resultRevisionID: "rev_missing"
            ),
            resultPetAvailable: false
        )
        #expect(missingResult.resultReadiness == .missing)
        #expect(missingResult.resultReadiness.needsRecovery)
        #expect(missingResult.primaryAction == .unavailable)
    }

    @Test
    func submittedBriefIsStableCompactAndPathFree() {
        let description = """
        A small fox

        with a luminous tail and patient expression.
        """
        let input = GenerationForm(
            description: description,
            style: StylePreset.semiRealistic.rawValue,
            quality: .low,
            referenceImages: [
                "/Users/example/private/reference-one.png",
                "/Users/example/private/reference-two.webp",
            ]
        )

        let first = MakerSubmittedBriefPresentation(
            form: input,
            localeIdentifier: "en"
        )
        let second = MakerSubmittedBriefPresentation(
            form: input,
            localeIdentifier: "en"
        )

        #expect(first == second)
        #expect(first.descriptionSummary
            == "A small fox with a luminous tail and patient expression.")
        #expect(first.styleTitle == "Semi-realistic")
        #expect(first.qualityTitle == "Low")
        #expect(first.referenceCount == 2)
        #expect(!String(describing: first).contains("/Users/example"))
        #expect(!String(describing: first).contains("reference-one"))
    }

    @Test
    func submittedBriefShowsOnlyTheFourStableMakerInputs() throws {
        let studio = try source("PetStudioView.swift")
        let summaryStart = try #require(studio.range(
            of: "struct SubmittedFormSummary"
        ))
        let summaryEnd = try #require(studio.range(
            of: "struct GenerationTimelineRow",
            range: summaryStart.upperBound ..< studio.endIndex
        ))
        let summary = String(
            studio[summaryStart.lowerBound ..< summaryEnd.lowerBound]
        )
        #expect(occurrences(of: "LabeledContent(", in: summary) == 3)
        #expect(summary.contains(".studioFieldStyle"))
        #expect(summary.contains(".studioFieldQuality"))
        #expect(summary.contains(".studioFieldReferences"))
        #expect(!summary.contains("AdvancedDetailsDisclosure("))
    }

    @Test
    func submittedDescriptionUsesUnicodeScalarBoundWithoutChangingTheForm() {
        let original = String(repeating: "星", count: 190)
        let input = form(description: original)
        let presentation = MakerSubmittedBriefPresentation(
            form: input,
            localeIdentifier: "zh-Hans"
        )

        #expect(presentation.descriptionSummary.unicodeScalars.count
            == MakerSubmittedBriefPresentation.maximumDescriptionScalars + 1)
        #expect(presentation.descriptionSummary.hasSuffix("…"))
        #expect(input.description == original)
    }

    @Test
    func resultLookupUsesExactSessionIdentityOnlyAfterSuccess() {
        let expected = pet(id: "pet_result")
        let other = pet(id: "pet_other")
        let succeeded = GenerationSession(
            state: .succeeded,
            jobID: "job",
            resultPetID: expected.id,
            resultRevisionID: "rev_result"
        )
        let running = GenerationSession(
            state: .running,
            jobID: "job",
            resultPetID: expected.id
        )

        #expect(MakerResultPresentation.resultPet(
            for: succeeded,
            in: [other, expected]
        )?.id == expected.id)
        #expect(MakerResultPresentation.resultPet(
            for: succeeded,
            in: [other]
        ) == nil)
        #expect(MakerResultPresentation.resultPet(
            for: running,
            in: [expected]
        ) == nil)
    }

    @Test
    func historyOutcomeFiltersDoNotMisclassifyActiveJobs() {
        #expect(MakerHistoryFilter.all.matches(.pending))
        #expect(MakerHistoryFilter.all.matches(.running))
        #expect(MakerHistoryFilter.all.matches(.waitingForUser))
        #expect(MakerHistoryFilter.succeeded.matches(.completed))
        #expect(!MakerHistoryFilter.succeeded.matches(.running))
        #expect(MakerHistoryFilter.failed.matches(.failed))
        #expect(!MakerHistoryFilter.failed.matches(.canceled))
        #expect(MakerHistoryFilter.cancelled.matches(.canceled))
        #expect(MakerHistoryFilter.allCases.map {
            $0.title(localeIdentifier: "zh-Hans")
        } == ["全部", "成功", "失败", "已取消"])
    }

    @Test
    func historyTimestampKeepsRelativeAndExactRepresentations() throws {
        let now = try #require(ISO8601DateFormatter().date(
            from: "2026-08-07T12:00:00Z"
        ))
        let timestamp = MakerHistoryTimestampPresentation(
            value: "2026-08-07T09:00:00Z",
            now: now,
            localeIdentifier: "en_US",
            timeZone: try #require(TimeZone(secondsFromGMT: 0))
        )

        #expect(timestamp.relative.contains("3"))
        #expect(timestamp.relative.lowercased().contains("hour"))
        #expect(timestamp.absolute != timestamp.relative)
        #expect(timestamp.absolute != "—")
        #expect(MakerHistoryTimestampPresentation(
            value: "not-a-date",
            now: now
        ) == MakerHistoryTimestampPresentation(
            value: "",
            now: now
        ))
    }

    @Test
    func historyProgressRemovesTechnicalIDsDeduplicatesAndBounds() {
        let firstThreadID = "019f6ed7-de50-7623-8462-6a857e367a96"
        let secondThreadID = "019f6ed7-de50-7623-8462-6a857e367a97"
        let messages = [
            GenerationMessage(
                id: "first",
                role: "assistant",
                content: "已创建 Codex App Server 会话 \(firstThreadID)，正在启动 Pet Studio brief turn。",
                progress: 0.08,
                createdAt: ""
            ),
            GenerationMessage(
                id: "duplicate",
                role: "assistant",
                content: "已创建 Codex App Server 会话 \(secondThreadID)，正在启动 Pet Studio brief turn。",
                progress: 0.08,
                createdAt: ""
            ),
            GenerationMessage(
                id: "brief",
                role: "assistant",
                content: "turn_id: \(secondThreadID) 正在处理蓝色围巾与绿色眼睛。",
                progress: 0.3,
                createdAt: ""
            ),
        ]

        let items = MakerHistoryProgressPresentation.items(messages)
        #expect(items.map(\.id) == ["first", "brief"])
        #expect(!items.map(\.content).joined().contains(firstThreadID))
        #expect(!items.map(\.content).joined().contains(secondThreadID))
        #expect(!items.map(\.content).joined().lowercased().contains("turn_id"))
        #expect(items.last?.content.contains("蓝色围巾与绿色眼睛") == true)

        let bounded = MakerHistoryProgressPresentation.items(
            (0 ..< 20).map { index in
                GenerationMessage(
                    id: "item-\(index)",
                    role: "assistant",
                    content: "Progress \(index)",
                    progress: Double(index) / 20,
                    createdAt: ""
                )
            }
        )
        #expect(bounded.count == MakerHistoryProgressPresentation.maximumItems)
        #expect(bounded.first?.id == "item-8")
    }

    @Test
    func briefGuidanceUsesThresholdTemplatesAndProducerCapabilityCopy() {
        #expect(!MakerBriefPresentation.showsDescriptionCount(scalarCount: 6_400))
        #expect(MakerBriefPresentation.showsDescriptionCount(scalarCount: 6_401))
        #expect(MakerBriefPresentation.descriptionCount(
            scalarCount: 6_401,
            localeIdentifier: "en"
        ) == "6,401/8,000 characters")

        let guidance = MakerBriefPresentation.qualityGuidance(
            .standard,
            localeIdentifier: "en"
        )
        #expect(guidance.contains("384×416"))
        #expect(guidance.contains("built-in Codex Studio"))
        #expect(guidance.contains("Low and Standard"))

        #expect(MakerBriefTemplate.allCases.map(\.rawValue)
            == ["appearance", "action", "palette"])
        #expect(MakerBriefTemplate.appearance.title(localeIdentifier: "zh-Hans") == "外观")
        #expect(MakerBriefTemplate.action.insertionText(localeIdentifier: "en")
            .hasPrefix("Actions:"))
        #expect(!MakerBriefTemplate.palette.systemImage.isEmpty)
    }

    private func form(
        description: String = "A calm companion"
    ) -> GenerationForm {
        GenerationForm(
            description: description,
            style: StylePreset.modern.rawValue,
            quality: .standard,
            referenceImages: []
        )
    }

    private func pet(id: String) -> PetSummary {
        PetSummary(
            id: id,
            name: id,
            style: StylePreset.modern.rawValue,
            quality: .standard,
            renderSize: .init(width: 384, height: 416),
            petpackPath: "/tmp/\(id).petpack",
            coverPath: "/tmp/\(id).png",
            active: false,
            createdAt: "2026-07-23T00:00:00Z"
        )
    }

    private func source(_ fileName: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Sources/AgentPetCompanion/Views/\(fileName)"
                ),
            encoding: .utf8
        )
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
