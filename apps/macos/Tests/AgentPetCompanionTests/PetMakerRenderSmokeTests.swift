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
            quality: .high,
            renderSize: .init(width: 384, height: 416),
            petpackPath: "/nonexistent/pet_maker_result.petpack",
            coverPath: "/nonexistent/pet_maker_result.png",
            revisionID: "rev_maker_result",
            revisionCount: 1,
            nativeFPS: 20,
            stateDurationsMS: customDurations,
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
                quality: .high,
                referenceImages: [],
                nativeFPS: 20,
                stateDurationsMS: customDurations
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
    private func makeStore() -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
    }

    private var customDurations: [String: Int] {
        Dictionary(
            uniqueKeysWithValues: PetAnimationContract.orderedStateNames.map {
                ($0, $0 == "start" || $0 == "done" ? 1_000 : 2_000)
            }
        )
    }
}
