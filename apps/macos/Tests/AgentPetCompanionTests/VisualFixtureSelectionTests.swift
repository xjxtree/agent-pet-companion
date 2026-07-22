import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("UI Next deterministic fixture selections")
struct VisualFixtureSelectionTests {
    @Test
    func defaultSelectionsPreserveSceneStorageValues() {
        let selections = APCVisualFixtureSelections.system

        #expect(selections.resolveConfigurationSection(stored: .messages) == .messages)
        #expect(selections.resolveConnectionSource(stored: .opencode) == .opencode)
    }

    @Test
    func fixtureSelectionsOverridePersistedSubpagesWithoutMutatingThem() {
        let selections = APCVisualFixtureSelections(
            configurationSection: .appearance,
            connectionSource: .pi
        )

        #expect(selections.resolveConfigurationSection(stored: .messages) == .appearance)
        #expect(selections.resolveConnectionSource(stored: .codex) == .pi)
    }
}
