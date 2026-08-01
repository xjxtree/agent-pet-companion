import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct OverlayKeyboardFocusTests {
    @Test
    func capabilityAndActionTruthTableMatchesOverlayState() {
        let scenarios: [FocusScenario] = [
            .init(overlayEnabled: false, sessionCount: 0, expected: []),
            .init(overlayEnabled: false, sessionCount: 3, expected: []),
            .init(overlayEnabled: true, sessionCount: 0, expected: []),
            .init(
                overlayEnabled: true,
                sessionCount: 3,
                expected: [.bubbleSessions]
            ),
        ]

        for scenario in scenarios {
            let available = OverlayKeyboardFocusAction.availableActions(
                overlayEnabled: scenario.overlayEnabled,
                bubbleSessionCount: scenario.sessionCount
            )

            #expect(available == scenario.expected)
            #expect(
                OverlayKeyboardFocusAction.bubbleSessions.isAvailable(
                    overlayEnabled: scenario.overlayEnabled,
                    bubbleSessionCount: scenario.sessionCount
                ) == scenario.expected.contains(.bubbleSessions)
            )
        }
    }

    @MainActor
    @Test
    func appStoreFocusActionsGuardDisabledRoutesAndDispatchTypedEnabledActions() throws {
        let probe = OverlayKeyboardFocusHandlerProbe()
        let disabledStore = makeStore(probe: probe)
        disabledStore.behavior.enabled = false

        disabledStore.focusOverlayBubbleForKeyboardNavigation()
        #expect(probe.actions.isEmpty)

        let enabledStore = makeStore(probe: probe)
        try enabledStore.applyStateSnapshot([
            "revision": "keyboard-focus-test",
            "overlay_placement_revision": "0",
            "behavior": try jsonObject(BehaviorSettings()),
            "behavior_revision": "0",
            "pets": [],
            "active_agent_sessions": [],
            "active_agent_sessions_omitted_count": 1,
            "overlay_visibility": try jsonObject(OverlayVisibility()),
            "events": [],
            "connections": [],
        ])

        enabledStore.focusOverlayBubbleForKeyboardNavigation()

        #expect(probe.actions == [.bubbleSessions])
    }

    @MainActor
    private func makeStore(probe: OverlayKeyboardFocusHandlerProbe) -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { _ in },
            overlayKeyboardFocusHandler: { _, action in
                probe.actions.append(action)
            }
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
private final class OverlayKeyboardFocusHandlerProbe {
    var actions: [OverlayKeyboardFocusAction] = []
}

private struct FocusScenario {
    let overlayEnabled: Bool
    let sessionCount: Int
    let expected: Set<OverlayKeyboardFocusAction>
}
