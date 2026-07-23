import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct BehaviorSettingsViewTests {
    @Test
    func configurationHasExactlyTwoStableSubpages() {
        #expect(BehaviorSettingsSection.allCases == [.appearance, .messages])
        #expect(
            BehaviorSettingsSection.allCases.map(\.title)
                == [
                    APCLocalization.text(.configSectionAppearance),
                    APCLocalization.text(.configSectionMessages),
                ]
        )
    }

    @Test
    func messageCatalogContainsOnlyTheSupportedSourcesAndEvents() {
        #expect(BehaviorSettingsCatalog.sources == [.codex, .claudeCode, .pi, .opencode])
        #expect(
            BehaviorSettingsCatalog.events
                == [.start, .tool, .waiting, .review, .done, .failed]
        )
    }

    @Test
    func appearanceCatalogKeepsTheClosedThemeAndFpsProfiles() {
        #expect(BehaviorSettingsCatalog.appearanceThemes == [.system, .light, .dark])
        #expect(BehaviorSettingsCatalog.fpsProfiles == [.standard, .smooth])
        #expect(BehaviorSettingsCatalog.fpsProfiles.map(\.fps) == [10, 20])
        #expect(BehaviorSettingsCatalog.groupDisplays == [.stacked, .expanded])
    }

    @Test
    func nativeFrameRateLimitsTheAvailablePlaybackProfiles() {
        let standardPet = PetSummary(
            id: "pet_standard",
            name: "Standard",
            style: "pixel",
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: "/standard.petpack",
            coverPath: "",
            nativeFPS: 10,
            active: true,
            createdAt: "2026-07-22T00:00:00Z"
        )
        var smoothPet = standardPet
        smoothPet.nativeFPS = 20

        #expect(BehaviorSettingsCatalog.supportedFPSProfiles(for: standardPet) == [.standard])
        #expect(BehaviorSettingsCatalog.supportedFPSProfiles(for: smoothPet) == [.standard, .smooth])
        #expect(standardPet.effectiveFPSProfile(.smooth) == .standard)
    }

    @MainActor
    @Test
    func appStoreDefensivelyDowngradesUnsupportedSmoothSelection() {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        store.pets = [PetSummary(
            id: "pet_standard",
            name: "Standard",
            style: "pixel",
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: "/standard.petpack",
            coverPath: "",
            nativeFPS: 10,
            active: true,
            createdAt: "2026-07-22T00:00:00Z"
        )]
        var next = store.behavior
        next.fpsProfile = .smooth

        store.updateBehavior(next)

        #expect(store.behavior.fpsProfile == .standard)
        #expect(store.effectiveFPSProfile == .standard)
    }

    @Test
    func resizePreviewMatchesTheOverlayInteractionContract() {
        #expect(BehaviorSettingsLayout.resizeHitTarget == CGFloat(38))
        #expect(BehaviorSettingsLayout.resizeVisualSize == CGFloat(24))
        #expect(BehaviorSettingsLayout.resizeHitTarget > BehaviorSettingsLayout.resizeVisualSize)
    }

    @Test
    func wideSubnavigationFitsTheLongestEnglishLabelWithoutTruncation() {
        let titles = [
            APCLocalization.text(.configSectionAppearance, locale: "en"),
            APCLocalization.text(.configSectionMessages, locale: "en"),
        ]
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let longestTextWidth = titles
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0

        // Reserve native source-list space for the symbol, label gap, row insets,
        // split-view divider, and the trailing selection-pill breathing room.
        #expect(BehaviorSettingsLayout.navigationWidth >= longestTextWidth + 80)
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
