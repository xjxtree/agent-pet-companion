import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Maker reference image policy")
struct MakerReferenceImagePolicyTests {
    @Test
    func acceptsOnlyFourBoundedPNGOrWebPInputsBeforeStartingAJob() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try pngData()
        let urls = try (0 ..< 5).map { index in
            let url = directory.appendingPathComponent("reference-\(index).png")
            try png.write(to: url)
            return url
        }

        let admission = MakerReferenceImagePolicy.admit(existingPaths: [], urls: urls)

        #expect(admission.acceptedPaths.count == MakerReferenceImagePolicy.maximumCount)
        #expect(admission.issue == .tooMany)
        #expect(MakerReferenceImagePolicy.issue(for: admission.acceptedPaths) == nil)
    }

    @Test
    func rejectsUnsupportedMismatchedAndOversizedInputsAtTheFieldBoundary() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try pngData()

        let jpegName = directory.appendingPathComponent("reference.jpg")
        try png.write(to: jpegName)
        #expect(MakerReferenceImagePolicy.admit(
            existingPaths: [],
            urls: [jpegName]
        ).issue == .unsupportedFormat)

        let mismatchedWebP = directory.appendingPathComponent("reference.webp")
        try png.write(to: mismatchedWebP)
        #expect(MakerReferenceImagePolicy.admit(
            existingPaths: [],
            urls: [mismatchedWebP]
        ).issue == .invalidContent)

        let oversized = directory.appendingPathComponent("oversized.png")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: MakerReferenceImagePolicy.maximumFileBytes + 1)
        try handle.close()
        #expect(MakerReferenceImagePolicy.admit(
            existingPaths: [],
            urls: [oversized]
        ).issue == .tooLarge)
    }

    @Test
    func issueCopyIsLocalizedWithoutChangingTheTypedContract() {
        #expect(APCLocalizedPresentation.referenceImageIssue(.tooMany, locale: "en")
            == "You can add at most 4 reference images.")
        #expect(APCLocalizedPresentation.referenceImageIssue(.unsupportedFormat, locale: "zh-Hans")
            == "请选择 PNG 或 WebP 参考图。")
        #expect(APCLocalization.format(
            .studioMessageCreateRequestedFormat,
            locale: "en",
            APCLocalizedPresentation.styleTitle(.pixel, locale: "en")
        ) == "Create a Pixel art desktop pet from this brief.")
        #expect(APCLocalization.text(.studioMessageStartModifyFailed, locale: "en")
            == "Pet editing could not start. The current revision remains unchanged.")
        #expect(APCLocalizedPresentation.referenceImageIssue(
            .reselectionRequired(2),
            locale: "en"
        ) == "Select 2 reference image(s) again before retrying.")
        #expect(APCLocalization.format(.studioReferenceItemFormat, locale: "zh-Hans", 2)
            == "参考图 2")
    }

    @Test
    func recoveryProjectionAcceptsOnlyTheExpectedPrivateJobWorkspaceShape() throws {
        let root = try temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let references = root
            .appendingPathComponent("generation-jobs/job-safe/input/references", isDirectory: true)
        try FileManager.default.createDirectory(at: references, withIntermediateDirectories: true)
        let safe = references.appendingPathComponent("reference-00.png")
        try pngData().write(to: safe)
        let original = root.appendingPathComponent("original.png")
        try pngData().write(to: original)

        #expect(MakerReferenceImagePolicy.validatedRecoveryProjectionPath(
            safe.path,
            jobID: "job-safe",
            index: 0
        ) == safe.path)
        #expect(MakerReferenceImagePolicy.validatedRecoveryProjectionPath(
            original.path,
            jobID: "job-safe",
            index: 0
        ) == nil)
        #expect(MakerReferenceImagePolicy.validatedRecoveryProjectionPath(
            safe.path,
            jobID: "job-other",
            index: 0
        ) == nil)
        #expect(MakerReferenceImagePolicy.validatedRecoveryProjectionPath(
            safe.path,
            jobID: "job-safe",
            index: 1
        ) == nil)
    }

    @Test
    func failedCreateRetryUsesTheEditedDraftInsteadOfTheSubmittedForm() throws {
        var editedDurations = PetAnimationContract.defaultStateDurationsMS
        editedDurations["idle"] = 1_000
        editedDurations["done"] = 2_000
        let oldForm = GenerationForm(
            description: "old brief",
            style: StylePreset.realistic.rawValue,
            quality: .standard,
            referenceImages: []
        )
        let session = GenerationSession(
            state: .failed,
            jobID: "job_failed",
            submittedForm: oldForm,
            operation: .create
        )

        let retry = try #require(PetStudioDraftPolicy.retryForm(
            session: session,
            descriptionText: "edited brief",
            style: .pixel,
            quality: .ultra,
            referenceImages: [],
            nativeFPS: 20,
            stateDurationsMS: editedDurations
        ))

        #expect(retry.description == "edited brief")
        #expect(retry.description != oldForm.description)
        #expect(retry.style == StylePreset.pixel.rawValue)
        #expect(retry.quality == .ultra)
        #expect(retry.nativeFPS == 20)
        #expect(retry.stateDurationsMS == editedDurations)
    }

    @MainActor
    @Test
    func createAndEditSessionsSubmitTheSelectedOrBaselineTiming() {
        var durations = PetAnimationContract.defaultStateDurationsMS
        durations["idle"] = 1_000
        durations["done"] = 2_000
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            petCoreRequestOverride: { method, _, _ in
                if method == "generation.edit" {
                    return [
                        "job_id": "job_timing",
                        "native_fps": 20,
                        "state_durations_ms": durations,
                    ]
                }
                return ["job_id": "job_timing"]
            }
        )

        store.updateGenerationDescription("A pet with authored timing")
        store.selectGenerationNativeFPS(20)
        for stateName in PetAnimationContract.orderedStateNames {
            store.selectGenerationStateDuration(
                durations[stateName] ?? 1_000,
                for: stateName
            )
        }
        store.startGeneration()

        #expect(store.generationSession.operation == .create)
        #expect(store.generationSession.submittedForm?.nativeFPS == 20)
        #expect(store.generationSession.submittedForm?.stateDurationsMS == durations)

        _ = store.reduceGeneration(.reset)
        let pet = PetSummary(
            id: "pet_authoredtiming",
            name: "Authored Timing",
            style: StylePreset.pixel.rawValue,
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: "/tmp/pet_authoredtiming.petpack",
            coverPath: "",
            nativeFPS: 20,
            stateDurationsMS: durations,
            active: false,
            createdAt: "2026-07-23T00:00:00Z"
        )
        store.startPetEdit(pet, instruction: "Keep the animation timing")

        #expect(store.generationSession.operation == .modify)
        #expect(store.generationSession.submittedForm?.nativeFPS == pet.nativeFPS)
        #expect(store.generationSession.submittedForm?.stateDurationsMS == pet.stateDurationsMS)
    }

    @MainActor
    @Test
    func historicalEditReceiptImmediatelyReconcilesTheSelectedBaselineTiming() async {
        let receiptGate = HistoricalEditReceiptGate()
        let baselineRevisionID = "rev_11111111111111111111111111111111"
        var currentHeadDurations = PetAnimationContract.defaultStateDurationsMS
        currentHeadDurations["idle"] = 1_000
        currentHeadDurations["start"] = 2_000
        let baselineDurations = PetAnimationContract.defaultStateDurationsMS
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            petCoreRequestOverride: { method, _, _ in
                switch method {
                case "generation.edit":
                    return await receiptGate.request()
                case "generation.messages.wait":
                    await Task.yield()
                    return ["revision": "0", "messages": []]
                default:
                    return [:]
                }
            }
        )
        let currentHead = PetSummary(
            id: "pet_historicaltiming",
            name: "Historical Timing",
            style: StylePreset.pixel.rawValue,
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: "/tmp/pet_historicaltiming.petpack",
            coverPath: "",
            revisionID: "rev_22222222222222222222222222222222",
            revisionCount: 2,
            nativeFPS: 20,
            stateDurationsMS: currentHeadDurations,
            active: false,
            createdAt: "2026-07-23T00:00:00Z"
        )

        store.startPetEdit(
            currentHead,
            baselineRevisionID: baselineRevisionID,
            instruction: "Edit the selected historical revision"
        )
        await receiptGate.waitUntilRequested()

        #expect(store.generationSession.state == .starting)
        #expect(store.generationSession.submittedForm?.nativeFPS == 20)
        #expect(store.generationSession.submittedForm?.stateDurationsMS == currentHeadDurations)

        receiptGate.resume(with: [
            "job_id": "job_historical_timing",
            "baseline_revision_id": baselineRevisionID,
            "native_fps": 10,
            "state_durations_ms": baselineDurations,
        ])
        for _ in 0 ..< 100 where store.generationSession.jobID == nil {
            await Task.yield()
        }

        #expect(store.generationSession.jobID == "job_historical_timing")
        #expect(store.generationSession.baselineRevisionID == baselineRevisionID)
        #expect(store.generationSession.submittedForm?.nativeFPS == 10)
        #expect(store.generationSession.submittedForm?.stateDurationsMS == baselineDurations)
        _ = store.reduceGeneration(.reset)
    }

    @Test
    func modifyRetryReusesTheServerOwnedFormAndHistoricalBaseline() {
        #expect(!GenerationRetryRequestPolicy.includesForm(for: .modify))
        #expect(GenerationRetryRequestPolicy.includesForm(for: .create))
    }

    @Test
    func makerDescriptionInputIsBoundedBeforeSubmission() async {
        let store = await MainActor.run {
            AppStore(
                bootstrapHooks: AppStoreBootstrapHooks(
                    ensureRunning: { .alreadyHealthy },
                    recover: { .alreadyHealthy },
                    refreshSnapshot: { _ in },
                    onReady: { _ in }
                )
            )
        }
        await MainActor.run {
            store.updateGenerationDescription(
                String(repeating: "a", count: AIPetMakerDefaults.maximumDescriptionCharacters + 10)
            )
            #expect(store.descriptionText.count == AIPetMakerDefaults.maximumDescriptionCharacters)
        }
    }

    @Test
    func makerDescriptionUsesTheSameUnicodeScalarBoundaryAsPetCore() async {
        let combinedGrapheme = "e\u{301}"
        let overLimit = String(
            repeating: combinedGrapheme,
            count: AIPetMakerDefaults.maximumDescriptionCharacters
        )

        let store = await MainActor.run {
            AppStore(
                bootstrapHooks: AppStoreBootstrapHooks(
                    ensureRunning: { .alreadyHealthy },
                    recover: { .alreadyHealthy },
                    refreshSnapshot: { _ in },
                    onReady: { _ in }
                )
            )
        }
        await MainActor.run {
            store.updateGenerationDescription(overLimit)
            #expect(
                GenerationPromptPolicy.scalarCount(store.descriptionText)
                    == AIPetMakerDefaults.maximumDescriptionCharacters
            )
            #expect(store.descriptionText.count < overLimit.count)
            #expect(GenerationPromptPolicy.isValid(store.descriptionText))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apc-reference-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pngData() throws -> Data {
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
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
private final class HistoricalEditReceiptGate {
    private var responseContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var response: [String: Any] = [:]

    func request() async -> [String: Any] {
        await withCheckedContinuation { continuation in
            responseContinuation = continuation
            let waiters = requestWaiters
            requestWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        return response
    }

    func waitUntilRequested() async {
        if responseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func resume(with response: [String: Any]) {
        self.response = response
        let continuation = responseContinuation
        responseContinuation = nil
        continuation?.resume()
    }
}
