import SwiftUI

/// Optional visual-accessibility values used by deterministic fixture hosts.
/// Nil means "follow the corresponding macOS setting", which is always the
/// production default.
struct APCVisualAccessibilityOverrides: Equatable, Sendable {
    var reduceTransparency: Bool?
    var increasedContrast: Bool?
    var reduceMotion: Bool?

    init(
        reduceTransparency: Bool? = nil,
        increasedContrast: Bool? = nil,
        reduceMotion: Bool? = nil
    ) {
        self.reduceTransparency = reduceTransparency
        self.increasedContrast = increasedContrast
        self.reduceMotion = reduceMotion
    }

    static let system = Self()
    static let standardFixture = Self(
        reduceTransparency: false,
        increasedContrast: false,
        reduceMotion: false
    )
}

struct APCVisualAccessibilityPresentation: Equatable, Sendable {
    let reduceTransparency: Bool
    let increasedContrast: Bool
    let reduceMotion: Bool

    static func resolve(
        systemReduceTransparency: Bool,
        systemIncreasedContrast: Bool,
        systemReduceMotion: Bool,
        overrides: APCVisualAccessibilityOverrides
    ) -> Self {
        Self(
            reduceTransparency: overrides.reduceTransparency ?? systemReduceTransparency,
            increasedContrast: overrides.increasedContrast ?? systemIncreasedContrast,
            reduceMotion: overrides.reduceMotion ?? systemReduceMotion
        )
    }
}

private struct APCVisualAccessibilityOverridesKey: EnvironmentKey {
    static let defaultValue = APCVisualAccessibilityOverrides.system
}

extension EnvironmentValues {
    var apcVisualAccessibilityOverrides: APCVisualAccessibilityOverrides {
        get { self[APCVisualAccessibilityOverridesKey.self] }
        set { self[APCVisualAccessibilityOverridesKey.self] = newValue }
    }
}
