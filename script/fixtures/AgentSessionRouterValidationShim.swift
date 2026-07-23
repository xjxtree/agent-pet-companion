import AgentPetCompanionCore

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
