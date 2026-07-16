import Testing
@testable import AgentPetCompanion

@Suite
struct BubbleGlassRegressionTests {
    @Test
    func maximumClearSurfaceAddsNoSolidBackdrop() {
        #expect(APCBubbleGlassStyle.backdropOpacity == 0)
        #expect(APCBubbleGlassStyle.borderOpacity == 0)
        #expect(APCBubbleGlassStyle.legacyBackdropOpacity > 0)
    }

    @Test
    func clearSurfaceNeverAttenuatesItsForeground() {
        #expect(APCBubbleForegroundStyle.contentOpacity == 1)
        #expect(APCBubbleForegroundStyle.secondaryContentOpacity >= 0.85)
        #expect(APCBubbleForegroundStyle.lightHaloOpacity > 0)
        #expect(APCBubbleForegroundStyle.darkHaloOpacity > 0)
        #expect(APCBubbleForegroundStyle.darkHaloOpacity > APCBubbleForegroundStyle.lightHaloOpacity)
    }

    @Test
    func accessibilityFallbacksRemainDarkerThanLegacyMaterial() {
        #expect(
            APCBubbleGlassStyle.increasedContrastBackdropOpacity
                > APCBubbleGlassStyle.legacyBackdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.reducedTransparencyBackdropOpacity
                > APCBubbleGlassStyle.increasedContrastBackdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.reducedTransparencyBorderOpacity
                > APCBubbleGlassStyle.legacyBorderOpacity
        )
    }
}
