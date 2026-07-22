import Testing
@testable import AgentPetCompanion

@Suite("UI Next visual accessibility overrides")
struct VisualAccessibilityOverridesTests {
    @Test
    func systemDefaultsLeaveEveryAccessibilitySettingUnchanged() {
        let resolved = APCVisualAccessibilityPresentation.resolve(
            systemReduceTransparency: true,
            systemIncreasedContrast: false,
            systemReduceMotion: true,
            overrides: .system
        )

        #expect(resolved.reduceTransparency)
        #expect(!resolved.increasedContrast)
        #expect(resolved.reduceMotion)
    }

    @Test
    func fixtureOverridesReplaceOnlyTheRequestedSystemSetting() {
        #expect(APCVisualAccessibilityPresentation.resolve(
            systemReduceTransparency: true,
            systemIncreasedContrast: true,
            systemReduceMotion: true,
            overrides: .standardFixture
        ) == APCVisualAccessibilityPresentation(
            reduceTransparency: false,
            increasedContrast: false,
            reduceMotion: false
        ))

        #expect(APCVisualAccessibilityPresentation.resolve(
            systemReduceTransparency: false,
            systemIncreasedContrast: false,
            systemReduceMotion: false,
            overrides: .init(reduceTransparency: true)
        ) == APCVisualAccessibilityPresentation(
            reduceTransparency: true,
            increasedContrast: false,
            reduceMotion: false
        ))

        #expect(APCVisualAccessibilityPresentation.resolve(
            systemReduceTransparency: false,
            systemIncreasedContrast: false,
            systemReduceMotion: false,
            overrides: .init(increasedContrast: true)
        ).increasedContrast)

        #expect(APCVisualAccessibilityPresentation.resolve(
            systemReduceTransparency: false,
            systemIncreasedContrast: false,
            systemReduceMotion: false,
            overrides: .init(reduceMotion: true)
        ).reduceMotion)
    }

    @Test
    func eachMatrixModeResolvesToADeterministicPresentation() {
        #expect(UINextAccessibilityFixtureMode.standard.presentation
            == .init(reduceTransparency: false, increasedContrast: false, reduceMotion: false))
        #expect(UINextAccessibilityFixtureMode.reduceTransparency.presentation
            == .init(reduceTransparency: true, increasedContrast: false, reduceMotion: false))
        #expect(UINextAccessibilityFixtureMode.increasedContrast.presentation
            == .init(reduceTransparency: false, increasedContrast: true, reduceMotion: false))
        #expect(UINextAccessibilityFixtureMode.reduceMotion.presentation
            == .init(reduceTransparency: false, increasedContrast: false, reduceMotion: true))
    }
}
