import AgentPetCompanionCore
import Foundation
import Testing
@testable import AgentPetCompanion

@Suite("AI Pet Maker experience presentation")
struct MakerExperiencePresentationTests {
    @Test
    func sourceKeepsDescribeSessionAndResultAsDistinctSurfaces() throws {
        let studioSource = try source("PetStudioView.swift")
        let resultSource = try source("PetMakerResultView.swift")

        #expect(studioSource.contains("if experience.showsCenteredBrief"))
        #expect(studioSource.contains("PrimaryExperienceCard("))
        #expect(studioSource.contains("AdvancedDetailsDisclosure("))
        #expect(studioSource.contains("InlineRecoveryBanner("))
        #expect(!studioSource.contains("private var welcomeState"))
        #expect(!studioSource.contains("maker.layout.two-stage"))

        #expect(resultSource.contains("PetPreviewStage("))
        #expect(resultSource.contains(
            "experience.primaryAction == .usePet"
        ))
        #expect(resultSource.contains("PetMakerPrimaryAction.continueEditing"))
        #expect(resultSource.contains(".libraryExportAction"))
        #expect(resultSource.contains("result-technical"))
        #expect(studioSource.contains("action: experience.primaryAction"))
        #expect(resultSource.contains("primaryAction: primaryAction"))
        #expect(resultSource.contains("action: .usePet"))
        #expect(resultSource.contains("PetAssetRecoveryCard("))
        #expect(!resultSource.contains("status: statusPresentation"))
        #expect(!resultSource.contains("private var statusPresentation"))
        #expect(resultSource.contains(
            "title: resultPet?.name ?? APCLocalization.text(.libraryMissingPreview)"
        ))
        #expect(!resultSource.contains(
            "title: resultPet?.name ?? APCLocalization.text(.studioSucceededTitle)"
        ))
        #expect(resultSource.contains(
            "resultPet.flatMap { store.petAssetWarningIndex[$0.id] }"
        ))
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
            quality: .high,
            referenceImages: [
                "/Users/example/private/reference-one.png",
                "/Users/example/private/reference-two.webp",
            ],
            nativeFPS: 20,
            stateDurationsMS: customDurations
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
        #expect(first.qualityTitle == "High")
        #expect(first.motionTitle == "Smooth Motion")
        #expect(first.referenceCount == 2)
        #expect(first.nativeFPS == 20)
        #expect(first.stateDurationsMS == customDurations)
        #expect(!String(describing: first).contains("/Users/example"))
        #expect(!String(describing: first).contains("reference-one"))
    }

    @Test
    func submittedBriefShowsOneCollapsedMotionSummaryAndOnlyTwoExpandedDetails() throws {
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
        let disclosureStart = try #require(summary.range(
            of: "AdvancedDetailsDisclosure("
        ))
        let disclosureContentStart = try #require(summary.range(
            of: ") {",
            range: disclosureStart.upperBound ..< summary.endIndex
        ))
        let disclosureEnd = try #require(summary.range(
            of: "\n                }\n            }\n            .font",
            range: disclosureContentStart.upperBound ..< summary.endIndex
        ))

        let ordinarySummary = String(summary[..<disclosureStart.lowerBound])
        let disclosureHeader = String(
            summary[disclosureStart.lowerBound ..< disclosureContentStart.lowerBound]
        )
        let expandedDetails = String(
            summary[disclosureContentStart.upperBound ..< disclosureEnd.lowerBound]
        )

        #expect(occurrences(of: "LabeledContent(", in: ordinarySummary) == 3)
        #expect(!ordinarySummary.contains(".studioTimingHeading"))
        #expect(!ordinarySummary.contains("presentation.motionTitle"))

        #expect(occurrences(of: ".studioTimingHeading", in: disclosureHeader) == 1)
        #expect(occurrences(of: "presentation.motionTitle", in: disclosureHeader) == 1)

        #expect(occurrences(of: "LabeledContent(", in: expandedDetails) == 2)
        #expect(occurrences(of: ".studioTimingNativeFPS", in: expandedDetails) == 1)
        #expect(occurrences(of: ".studioTimingActionDurations", in: expandedDetails) == 1)
        #expect(!expandedDetails.contains(".studioFieldStyle"))
        #expect(!expandedDetails.contains(".studioFieldQuality"))
        #expect(!expandedDetails.contains(".studioFieldReferences"))
        #expect(!expandedDetails.contains("presentation.motionTitle"))
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
    func standardAndSmoothCopyRetainExactTechnicalValues() {
        #expect(MakerMotionPresentation.profile(nativeFPS: 10) == .standard)
        #expect(MakerMotionPresentation.profile(nativeFPS: 20) == .smooth)
        #expect(MakerMotionPresentation.title(
            nativeFPS: 10,
            localeIdentifier: "en"
        ) == "Standard Motion")
        #expect(MakerMotionPresentation.title(
            nativeFPS: 20,
            localeIdentifier: "zh-Hans"
        ) == "流畅动效")
        #expect(MakerMotionPresentation.exactValue(nativeFPS: 10) == "10 FPS")
        #expect(MakerMotionPresentation.exactValue(nativeFPS: 20) == "20 FPS")
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

    private var customDurations: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: PetAnimationContract.orderedStateNames.map {
                ($0, $0 == "idle" || $0 == "done" ? 1_000 : 2_000)
            }
        )
    }

    private func form(
        description: String = "A calm companion"
    ) -> GenerationForm {
        GenerationForm(
            description: description,
            style: StylePreset.modern.rawValue,
            quality: .high,
            referenceImages: [],
            nativeFPS: 10,
            stateDurationsMS: PetAnimationContract.defaultStateDurationsMS
        )
    }

    private func pet(id: String) -> PetSummary {
        PetSummary(
            id: id,
            name: id,
            style: StylePreset.modern.rawValue,
            quality: .high,
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
