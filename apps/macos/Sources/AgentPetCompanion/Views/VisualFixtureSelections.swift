import AgentPetCompanionCore
import SwiftUI

/// Deterministic navigation inputs for non-interactive visual fixtures.
/// Production uses the persisted scene values because both overrides are nil.
struct APCVisualFixtureSelections: Equatable {
    var configurationSection: BehaviorSettingsSection?
    var connectionSource: AgentSource?

    init(
        configurationSection: BehaviorSettingsSection? = nil,
        connectionSource: AgentSource? = nil
    ) {
        self.configurationSection = configurationSection
        self.connectionSource = connectionSource
    }

    static let system = Self()

    func resolveConfigurationSection(
        stored: BehaviorSettingsSection
    ) -> BehaviorSettingsSection {
        configurationSection ?? stored
    }

    func resolveConnectionSource(stored: AgentSource) -> AgentSource {
        connectionSource ?? stored
    }
}

private struct APCVisualFixtureSelectionsKey: EnvironmentKey {
    static let defaultValue = APCVisualFixtureSelections.system
}

extension EnvironmentValues {
    var apcVisualFixtureSelections: APCVisualFixtureSelections {
        get { self[APCVisualFixtureSelectionsKey.self] }
        set { self[APCVisualFixtureSelectionsKey.self] = newValue }
    }
}
