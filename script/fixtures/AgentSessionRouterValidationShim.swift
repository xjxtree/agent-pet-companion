import AgentPetCompanionCore
import SwiftUI

/// `Localization.swift` includes the production interface-language modifier.
/// The standalone overlay modules do not link the real AppStore, so keep only
/// the two observable values required to type-check that modifier.
@MainActor
final class AppStore: ObservableObject {
    @Published var behavior = BehaviorSettings()
    var interfaceLocaleIdentifier: String { "en" }
}

/// `validate_overlay_offline.sh` recompiles geometry and frame-pipeline sources
/// as small standalone modules. Production navigation is already exercised by
/// `AgentPetCompanion --run-ui-validation`; these standalone checks must never
/// substitute their own routing behavior.
enum AgentSessionRouter {
    static func validatedCapability(
        source: AgentSource?,
        sessionID: String?,
        navigation: AgentSessionNavigation
    ) -> NavigationCapability {
        fatalError(
            "The standalone geometry validation must not exercise navigation"
        )
    }
}
