import CoreGraphics
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct BehaviorSettingsNextTests {
    @Test
    func configurationHasExactlyTwoStableSubpages() {
        #expect(BehaviorSettingsSection.allCases == [.appearance, .messages])
        #expect(BehaviorSettingsSection.allCases.map(\.title) == ["外观与桌宠", "消息与来源"])
    }

    @Test
    func messageCatalogContainsOnlyTheSupportedSourcesAndEvents() {
        #expect(BehaviorSettingsNextCatalog.sources == [.codex, .claudeCode, .pi, .opencode])
        #expect(
            BehaviorSettingsNextCatalog.events
                == [.start, .tool, .waiting, .review, .done, .failed]
        )
    }

    @Test
    func appearanceCatalogKeepsTheClosedThemeAndFpsProfiles() {
        #expect(BehaviorSettingsNextCatalog.appearanceThemes == [.system, .light, .dark])
        #expect(BehaviorSettingsNextCatalog.fpsProfiles == [.standard, .smooth])
        #expect(BehaviorSettingsNextCatalog.fpsProfiles.map(\.fps) == [12, 20])
        #expect(BehaviorSettingsNextCatalog.groupDisplays == [.stacked, .expanded])
    }

    @Test
    func resizePreviewMatchesTheOverlayInteractionContract() {
        #expect(BehaviorSettingsNextLayout.resizeHitTarget == CGFloat(38))
        #expect(BehaviorSettingsNextLayout.resizeVisualSize == CGFloat(24))
        #expect(BehaviorSettingsNextLayout.resizeHitTarget > BehaviorSettingsNextLayout.resizeVisualSize)
    }

    @MainActor
    @Test
    func transparencyDragPreviewsLocallyAndCommitsExactlyOneRPC() async throws {
        let probe = BehaviorRequestProbe()
        let persisted = BehaviorSettings(bubbleTransparency: 0.8)
        let persistedObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(persisted)
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            petCoreRequestOverride: { method, params, _ in
                probe.requests.append((method, params))
                return [
                    "behavior": persistedObject,
                    "revision": "1",
                ]
            }
        )
        let original = store.behavior.bubbleTransparency

        store.previewBubbleTransparency(0.6)
        store.previewBubbleTransparency(0.7)
        store.previewBubbleTransparency(0.8)

        #expect(probe.requests.isEmpty)
        #expect(store.behavior.bubbleTransparency == 0.8)

        store.commitBubbleTransparency(from: original)
        await store.waitForBehaviorPersistence()

        #expect(probe.requests.count == 1)
        #expect(probe.requests.first?.method == "behavior.patch")
        let parameters = probe.requests.first?.params as? [String: Any]
        let changes = parameters?["changes"] as? [String: Any]
        #expect(changes?["bubble_transparency"] as? Double == 0.8)
    }
}

@MainActor
private final class BehaviorRequestProbe {
    var requests: [(method: String, params: Any)] = []
}
