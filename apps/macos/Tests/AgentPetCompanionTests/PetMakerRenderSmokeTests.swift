import AgentPetCompanionCore
import AppKit
import SwiftUI
import Testing
@testable import AgentPetCompanion

@Suite("AI Pet Maker render smoke")
struct PetMakerRenderSmokeTests {
    @MainActor
    @Test
    func describePhaseRendersAtMinimumContentWidth() throws {
        let bitmap = try render(
            AIPetMakerView(),
            store: makeStore(),
            size: CGSize(
                width: SharedProductComponentLayout.supportedMinimumContentWidth + 48,
                height: 760
            ),
            shellMode: .singleContent
        )

        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
        #expect(hasVisibleContent(bitmap))
    }

    @MainActor
    @Test
    func completedPhaseRendersResultBeforeTechnicalDetails() throws {
        let store = makeStore()
        let resultPet = PetSummary(
            id: "pet_maker_result",
            name: "Maker Result",
            style: StylePreset.semiRealistic.rawValue,
            quality: .standard,
            renderSize: .init(width: 384, height: 416),
            petpackPath: "/nonexistent/pet_maker_result.petpack",
            coverPath: "/nonexistent/pet_maker_result.png",
            revisionID: "rev_maker_result",
            revisionCount: 1,
            active: false,
            createdAt: "2026-07-23T00:00:00Z"
        )
        store.pets = [resultPet]
        _ = store.reduceGeneration(.restore(GenerationSessionRestore(
            state: .succeeded,
            jobID: "job_maker_result",
            submittedForm: GenerationForm(
                description: "A luminous fox that celebrates completed work",
                style: StylePreset.semiRealistic.rawValue,
                quality: .standard,
                referenceImages: []
            ),
            messages: [
                GenerationMessage(
                    role: "assistant",
                    content: "The validated pet is ready.",
                    progress: 1,
                    createdAt: "2026-07-23T00:00:00Z"
                ),
            ],
            progress: 1,
            messageRevision: "1",
            operation: .create,
            resultPetID: resultPet.id,
            resultRevisionID: "rev_maker_result",
            validationSummary: .init(
                ok: true,
                stateCount: 7,
                frameCount: 240,
                warningCount: 0
            ),
            referenceReselectionCount: 0
        )))

        let bitmap = try render(
            AIPetMakerView(),
            store: store,
            size: CGSize(width: 856, height: 760),
            shellMode: .allColumns
        )

        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
        #expect(hasVisibleContent(bitmap))
        #expect(MakerResultPresentation.resultPet(
            for: store.generationSession,
            in: store.pets
        )?.revisionID == "rev_maker_result")
    }

    @MainActor
    @Test
    func sessionWorkspaceRendersACompletedResultAtDesktopSize() async throws {
        let resultPet = PetSummary(
            id: "pet_history_result",
            name: "History Result",
            style: StylePreset.modern.rawValue,
            quality: .standard,
            renderSize: .init(width: 384, height: 416),
            petpackPath: "/nonexistent/pet_history_result.petpack",
            coverPath: "/nonexistent/pet_history_result.png",
            active: false,
            createdAt: "2026-08-07T00:00:00Z"
        )
        let store = makeStore { method, _, _ in
            switch method {
            case "generation.history.list":
                return [
                    "ok": true,
                    "jobs": [[
                        "job_id": "job_history_result",
                        "status": "completed",
                        "operation": "create",
                        "brief_preview": "A calm companion with a blue scarf",
                        "style": StylePreset.modern.rawValue,
                        "quality": QualityLevel.standard.rawValue,
                        "reference_count": 0,
                        "result_pet_id": resultPet.id,
                        "retry_of_job_id": NSNull(),
                        "created_at": "2026-08-07T00:00:00Z",
                        "updated_at": "2026-08-07T00:01:00Z",
                    ]],
                    "truncated": false,
                ]
            case "generation.history.detail":
                return [
                    "ok": true,
                    "found": true,
                    "job_id": "job_history_result",
                    "status": "completed",
                    "operation": "create",
                    "description": "A calm companion with a blue scarf",
                    "style": StylePreset.modern.rawValue,
                    "quality": QualityLevel.standard.rawValue,
                    "reference_count": 0,
                    "result_pet_id": resultPet.id,
                    "retry_of_job_id": NSNull(),
                    "revision_id": "rev_history_result",
                    "created_at": "2026-08-07T00:00:00Z",
                    "updated_at": "2026-08-07T00:01:00Z",
                    "progress_messages": [[
                        "id": "progress_history_result",
                        "role": "assistant",
                        "kind": "generation_progress",
                        "content": "Validated the final pet package.",
                        "progress": 1.0,
                        "created_at": "2026-08-07T00:01:00Z",
                    ]],
                    "latest_codex_excerpt": "The pet is ready.",
                    "message_count": 1,
                    "messages_truncated": false,
                    "session": [
                        "availability": "not_created",
                        "can_open": false,
                    ],
                ]
            default:
                throw PetCoreClientError.invalidResponse
            }
        }
        store.pets = [resultPet]
        await store.refreshGenerationHistory()
        await store.selectGenerationHistoryJobAndWait("job_history_result")

        let bitmap = try render(
            MakerSessionWorkspace(),
            store: store,
            size: CGSize(width: 980, height: 720),
            shellMode: .allColumns
        )

        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
        #expect(hasVisibleContent(bitmap))
        #expect(store.selectedGenerationHistoryResultPet?.id == resultPet.id)
    }

    @MainActor
    private func render<Content: View>(
        _ view: Content,
        store: AppStore,
        size: CGSize,
        shellMode: ControlCenterShellMode
    ) throws -> NSBitmapImageRep {
        let root = view
            .environmentObject(store)
            .environment(\.controlCenterShellMode, shellMode)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    private func hasVisibleContent(_ bitmap: NSBitmapImageRep) -> Bool {
        let stride = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 32)
        for x in Swift.stride(from: 0, to: bitmap.pixelsWide, by: stride) {
            for y in Swift.stride(from: 0, to: bitmap.pixelsHigh, by: stride) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.05 { return true }
            }
        }
        return false
    }

    @MainActor
    private func makeStore(
        request: AppStore.PetCoreRequestOverride? = nil
    ) -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            petCoreRequestOverride: request,
            initialPetStudioCodexAvailability: .available
        )
    }

}
