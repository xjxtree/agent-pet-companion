import Testing
@testable import AgentPetCompanion

@Suite
struct BubbleGlassRegressionTests {
    @Test
    func nativeClearSurfaceDoesNotAddAnOpacityLayer() {
        #expect(APCBubbleGlassStyle.backdropOpacity == 0)
        #expect(APCBubbleGlassStyle.borderOpacity == 0)
    }

    @Test
    func clearSurfaceNeverAttenuatesItsForeground() {
        #expect(APCBubbleForegroundStyle.contentOpacity == 1)
        #expect(APCBubbleForegroundStyle.lightHaloOpacity > 0)
        #expect(APCBubbleForegroundStyle.darkHaloOpacity > 0)
    }
}
