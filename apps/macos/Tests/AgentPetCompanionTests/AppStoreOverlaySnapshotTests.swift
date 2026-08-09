import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct AppStoreOverlaySnapshotTests {
    @MainActor
    @Test
    func activeAgentStateUsesAOneSecondDisplayRefreshBudget() {
        #expect(AppStore.stateWaitTimeoutMilliseconds(
            generationIsActive: false,
            hasActiveAgentState: true
        ) == 1_000)
        #expect(AppStore.stateWaitTimeoutMilliseconds(
            generationIsActive: false,
            hasActiveAgentState: false
        ) == 30_000)
    }

    @MainActor
    @Test
    func idleStateRestsWithoutAPlaceholderSessionBubble() throws {
        let store = makeStore()

        try store.applyStateSnapshot([
            "revision": "idle-overlay-1",
            "overlay_placement_revision": "0",
            "behavior": try jsonObject(BehaviorSettings()),
            "behavior_revision": "1",
            "pets": [],
            "active_agent_sessions": [],
            "active_agent_sessions_omitted_count": 0,
            "overlay_visibility": try jsonObject(OverlayVisibility(
                petVisible: true,
                statusBubbleVisible: true
            )),
            "events": [],
            "recent_events": [],
            "connections": [],
        ])

        #expect(store.overlayAvailableBubbleContents.isEmpty)
        #expect(!store.hasAvailableOverlayBubbleContent)

        store.overlayBubbleDismissed = true
        #expect(store.overlayBubbleContents.isEmpty)
        #expect(!store.hasAvailableOverlayBubbleContent)

        try store.applyStateSnapshot([
            "revision": "idle-overlay-hidden-2",
            "overlay_placement_revision": "0",
            "behavior": try jsonObject(BehaviorSettings(statusBubble: false)),
            "behavior_revision": "1",
            "pets": [],
            "active_agent_sessions": [],
            "active_agent_sessions_omitted_count": 0,
            "overlay_visibility": try jsonObject(OverlayVisibility(
                petVisible: true,
                statusBubbleVisible: false
            )),
            "events": [],
            "recent_events": [],
            "connections": [],
        ])
        #expect(store.overlayAvailableBubbleContents.isEmpty)
        #expect(!store.hasAvailableOverlayBubbleContent)
    }

    @MainActor
    @Test
    func productionSnapshotProjectsBoundedMultiSourceBubbleGroups() throws {
        let states = [
            makeState(source: .pi, session: "pi-tool", event: .tool, activatedSecond: 2),
            makeState(source: .codex, session: "codex-waiting", event: .waiting, activatedSecond: 7),
            makeState(source: .claudeCode, session: "claude-tool", event: .tool, activatedSecond: 4),
            makeState(source: .codex, session: "codex-tool", event: .tool, activatedSecond: 8),
            makeState(source: .pi, session: "pi-failed", event: .failed, activatedSecond: 1),
            makeState(source: .claudeCode, session: "claude-failed", event: .failed, activatedSecond: 5),
            makeState(source: .codex, session: "codex-failed", event: .failed, activatedSecond: 6),
            makeState(source: .pi, session: "pi-waiting", event: .waiting, activatedSecond: 3),
        ]
        let store = makeStore()

        try store.applyStateSnapshot([
            "revision": "multi-source-overlay-1",
            "overlay_placement_revision": "0",
            "behavior": try jsonObject(BehaviorSettings(sessionGroupDisplay: .stacked)),
            "behavior_revision": "1",
            "pets": [],
            "active_agent_sessions": try jsonArray(states),
            "active_agent_sessions_omitted_count": 4,
            "overlay_visibility": try jsonObject(OverlayVisibility(
                petVisible: true,
                statusBubbleVisible: true
            )),
            "events": [],
            "recent_events": [],
            "connections": [],
        ])

        #expect(store.activeAgentSessions.count == 8)
        #expect(store.activeAgentSessionsOmittedCount == 4)

        var contents = store.overlayAvailableBubbleContents
        #expect(contents.map(\.source) == [.codex, .claudeCode, .pi, nil])

        let codex = try #require(contents.first { $0.source == .codex })
        #expect(codex.sessionCount == 3)
        #expect(codex.sessions.map(\.eventType) == [.tool, .waiting, .failed])
        #expect(codex.isStacked)

        let claude = try #require(contents.first { $0.source == .claudeCode })
        #expect(claude.sessionCount == 2)
        #expect(claude.sessions.map(\.eventType) == [.failed, .tool])
        #expect(claude.isStacked)

        let pi = try #require(contents.first { $0.source == .pi })
        #expect(pi.sessionCount == 3)
        #expect(pi.sessions.map(\.eventType) == [.waiting, .tool, .failed])
        #expect(pi.isStacked)

        let omitted = try #require(contents.last)
        #expect(omitted.isOmittedSummary)
        #expect(omitted.sessionCount == 1)
        #expect(omitted.representedSessionCount == 4)
        #expect(store.overlayBubbleSessionCount == 12)

        store.toggleOverlayAgentGroup(.claudeCode)
        contents = store.overlayAvailableBubbleContents
        #expect(try #require(contents.first { $0.source == .codex }).isStacked)
        let expandedClaude = try #require(contents.first { $0.source == .claudeCode })
        #expect(expandedClaude.isExpanded)
        #expect(!expandedClaude.isStacked)
        #expect(try #require(contents.first { $0.source == .pi }).isStacked)

        let dismissedID = try #require(
            contents.first { $0.source == .codex }?.sessions.first { $0.eventType == .waiting }?.id
        )
        store.dismissOverlayBubble(eventID: dismissedID)

        contents = store.overlayAvailableBubbleContents
        let filteredCodex = try #require(contents.first { $0.source == .codex })
        #expect(filteredCodex.sessionCount == 2)
        #expect(filteredCodex.sessions.map(\.eventType) == [.tool, .failed])
        #expect(!contents.flatMap(\.sessions).contains { $0.id == dismissedID })
        #expect(store.overlayBubbleSessionCount == 11)
        #expect(try #require(contents.last).representedSessionCount == 4)
    }

    @MainActor
    @Test
    func ungroupedSessionCardsKeepStableSlotsUntilANewActivationEpoch() throws {
        let store = makeStore()
        let behavior = BehaviorSettings(
            groupSessionsByAgent: false,
            sessionGroupDisplay: .expanded
        )
        let older = makeState(
            source: .claudeCode,
            session: "older-claude",
            event: .tool,
            activatedSecond: 1
        )
        let newer = makeState(
            source: .codex,
            session: "newer-codex",
            event: .thinking,
            activatedSecond: 2
        )

        func apply(_ revision: String, _ states: [ActiveAgentState]) throws {
            try store.applyStateSnapshot([
                "revision": revision,
                "overlay_placement_revision": "0",
                "behavior": try jsonObject(behavior),
                "behavior_revision": "1",
                "pets": [],
                "active_agent_sessions": try jsonArray(states),
                "active_agent_sessions_omitted_count": 0,
                "overlay_visibility": try jsonObject(OverlayVisibility(
                    petVisible: true,
                    statusBubbleVisible: true
                )),
                "events": [],
                "recent_events": [],
                "connections": [],
            ])
        }

        try apply("ungrouped-1", [newer, older])
        var contents = store.overlayAvailableBubbleContents
        #expect(contents.allSatisfy { $0.isStandaloneSessionCard })
        #expect(contents.allSatisfy { $0.sessions.count == 1 })
        #expect(contents.compactMap { $0.sessions.first?.sessionID } == [
            "newer-codex",
            "older-claude",
        ])

        // A later tool/thinking edge changes content but stays in the same
        // activation epoch, so it must not cause visual list hopping.
        var olderChurn = older
        olderChurn.event.id = "event-older-claude-thinking"
        olderChurn.event.eventType = .thinking
        olderChurn.event.createdAt = "2026-07-22T00:00:03Z"
        olderChurn.overlayDisplay = AgentOverlayDisplay(summaryKind: .thinking)
        try apply("ungrouped-2", [olderChurn, newer])
        contents = store.overlayAvailableBubbleContents
        #expect(contents.compactMap { $0.sessions.first?.sessionID } == [
            "newer-codex",
            "older-claude",
        ])

        // A real new user/task epoch promotes the session exactly once.
        var reactivated = olderChurn
        reactivated.sessionActivatedAt = "2026-07-22T00:00:04Z"
        reactivated.event.id = "event-older-claude-reactivated"
        reactivated.event.createdAt = "2026-07-22T00:00:04Z"
        try apply("ungrouped-3", [reactivated, newer])
        contents = store.overlayAvailableBubbleContents
        #expect(contents.compactMap { $0.sessions.first?.sessionID } == [
            "older-claude",
            "newer-codex",
        ])
    }

    @MainActor
    @Test
    func ungroupedTrayUsesStableAttentionPartitionsAndAGlobalStack() throws {
        let store = makeStore()
        let states = [
            makeState(source: .codex, session: "running-new", event: .tool, activatedSecond: 5),
            makeState(source: .claudeCode, session: "needs-input", event: .waiting, activatedSecond: 1),
            makeState(source: .pi, session: "ready", event: .done, activatedSecond: 4),
            makeState(source: .codex, session: "running-old", event: .thinking, activatedSecond: 2),
            makeState(source: .claudeCode, session: "blocked", event: .failed, activatedSecond: 3),
        ]

        func apply(_ revision: String, display: SessionGroupDisplay) throws {
            try store.applyStateSnapshot([
                "revision": revision,
                "overlay_placement_revision": "0",
                "behavior": try jsonObject(BehaviorSettings(
                    groupSessionsByAgent: false,
                    sessionGroupDisplay: display
                )),
                "behavior_revision": "1",
                "pets": [],
                "active_agent_sessions": try jsonArray(states),
                "active_agent_sessions_omitted_count": 0,
                "overlay_visibility": try jsonObject(OverlayVisibility(
                    petVisible: true,
                    statusBubbleVisible: true
                )),
                "events": [],
                "recent_events": [],
                "connections": [],
            ])
        }

        try apply("ungrouped-partitions-expanded", display: .expanded)
        #expect(store.overlayAvailableBubbleContents.compactMap {
            $0.sessions.first?.sessionID
        } == [
            "needs-input",
            "blocked",
            "ready",
            "running-new",
            "running-old",
        ])

        try apply("ungrouped-partitions-stacked", display: .stacked)
        var contents = store.overlayAvailableBubbleContents
        #expect(contents.count == 1)
        #expect(contents.first?.sessions.first?.sessionID == "needs-input")
        #expect(contents.first?.representedSessionCount == 5)
        #expect(contents.first?.isStacked == true)

        #expect(store.overlayBubbleDisclosureAction == .expandStandaloneStack)
        store.stepOverlayBubbleDisclosure()
        contents = store.overlayAvailableBubbleContents
        #expect(contents.count == 5)
        #expect(contents.allSatisfy { $0.isStandaloneSessionCard })
        #expect(contents.allSatisfy { !$0.isStacked })
        #expect(contents.first?.disclosureSessionCount == 5)
        #expect(store.overlayBubbleSessionCount == 5)

        #expect(store.overlayBubbleDisclosureAction == .collapseStandaloneStack)
        store.stepOverlayBubbleDisclosure()
        #expect(store.overlayAvailableBubbleContents.count == 1)
        #expect(store.overlayBubbleDisclosureAction == .dismissBubble)

        store.stepOverlayBubbleDisclosure()
        #expect(store.overlayBubbleDismissed)
        #expect(store.overlayBubbleContents.isEmpty)
        #expect(store.overlayBubbleDisclosureAction == .revealCollapsedStandaloneStack)

        store.stepOverlayBubbleDisclosure()
        #expect(!store.overlayBubbleDismissed)
        #expect(store.overlayBubbleContents.count == 1)
        #expect(store.overlayBubbleDisclosureAction == .expandStandaloneStack)

        store.stepOverlayBubbleDisclosure()
        #expect(store.overlayBubbleContents.count == 5)
        #expect(store.overlayBubbleDisclosureAction == .collapseStandaloneStack)
    }

    @MainActor
    @Test
    func activatingACompletedSessionPersistsItsAcknowledgement() async throws {
        let acknowledgementID = "ack-" + String(repeating: "a", count: 64)
        var acknowledgedParams: [String: Any]?
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            agentSessionRouteOpener: { _ in .openedAgentHost },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "agent.session.acknowledge" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                acknowledgedParams = params as? [String: Any]
                return [
                    "ok": true,
                    "acknowledged": true,
                    "changed": true,
                    "acknowledgement_id": acknowledgementID,
                ]
            }
        )
        var completedState = try jsonObject(makeState(
            source: .codex,
            session: "completed-session",
            event: .done,
            activatedSecond: 1
        ))
        completedState["acknowledgement_id"] = acknowledgementID
        completedState["overlay_display"] = try jsonObject(AgentOverlayDisplay(
            summaryKind: .done,
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "chatgpt_app"
            )
        ))
        try store.applyStateSnapshot([
            "revision": "completed-session-1",
            "overlay_placement_revision": "0",
            "behavior": try jsonObject(BehaviorSettings(sessionGroupDisplay: .expanded)),
            "behavior_revision": "1",
            "pets": [],
            "active_agent_sessions": [completedState],
            "active_agent_sessions_omitted_count": 0,
            "overlay_visibility": try jsonObject(OverlayVisibility(
                petVisible: true,
                statusBubbleVisible: true
            )),
            "events": [],
            "recent_events": [],
            "connections": [],
        ])

        let session = try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
        store.activateOverlaySession(session)
        for _ in 0..<100 where acknowledgedParams == nil {
            await Task.yield()
        }

        #expect(acknowledgedParams?["acknowledgement_id"] as? String == acknowledgementID)
        #expect(store.overlayAvailableBubbleContents.isEmpty)
    }

    @MainActor
    @Test
    func acknowledgedCompletionDoesNotReappearAfterTransientProjectionGapWithoutNewActivity() async throws {
        let acknowledgementID = "ack-" + String(repeating: "9", count: 64)
        var acknowledgementCount = 0
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { _ in .openedAgentHost },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, _, _ in
                guard method == "agent.session.acknowledge" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                acknowledgementCount += 1
                return [
                    "ok": true,
                    "acknowledged": true,
                    "changed": true,
                    "acknowledgement_id": acknowledgementID,
                ]
            }
        )
        var completedState = try jsonObject(makeState(
            source: .claudeCode,
            session: "claude-acknowledged-session",
            event: .done,
            activatedSecond: 1
        ))
        completedState["acknowledgement_id"] = acknowledgementID
        completedState["overlay_display"] = try jsonObject(AgentOverlayDisplay(
            summaryKind: .done,
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "claude_app"
            )
        ))
        let unrelatedState = try jsonObject(makeState(
            source: .codex,
            session: "unrelated-active-session",
            event: .tool,
            activatedSecond: 3
        ))

        func applySnapshot(revision: String, sessions: [[String: Any]]) throws {
            try store.applyStateSnapshot([
                "revision": revision,
                "overlay_placement_revision": "0",
                "behavior": try jsonObject(BehaviorSettings(
                    sessionGroupDisplay: .expanded
                )),
                "behavior_revision": "1",
                "pets": [],
                "active_agent_sessions": sessions,
                "active_agent_sessions_omitted_count": 0,
                "overlay_visibility": try jsonObject(OverlayVisibility(
                    petVisible: true,
                    statusBubbleVisible: true
                )),
                "events": [],
                "recent_events": [],
                "connections": [],
            ])
        }

        try applySnapshot(
            revision: "claude-completed-1",
            sessions: [unrelatedState, completedState]
        )
        let completedSession = try #require(
            store.overlayAvailableBubbleContents
                .flatMap(\.sessions)
                .first { $0.source == .claudeCode }
        )
        store.activateOverlaySession(completedSession)
        for _ in 0 ..< 1_000 where acknowledgementCount == 0 {
            await Task.yield()
        }
        #expect(acknowledgementCount == 1)
        #expect(!store.overlayAvailableBubbleContents.flatMap(\.sessions).contains {
            $0.id == completedSession.id
        })

        try applySnapshot(revision: "claude-gap-2", sessions: [unrelatedState])
        #expect(!store.overlayAvailableBubbleContents.flatMap(\.sessions).contains {
            $0.id == completedSession.id
        })

        try applySnapshot(
            revision: "claude-stale-repeat-3",
            sessions: [unrelatedState, completedState]
        )
        #expect(
            !store.overlayAvailableBubbleContents.flatMap(\.sessions).contains {
                $0.id == completedSession.id
            },
            "The same acknowledged completion must not reopen without a new activation"
        )

        var reactivatedState = try jsonObject(makeState(
            source: .claudeCode,
            session: "claude-acknowledged-session",
            event: .start,
            activatedSecond: 2
        ))
        reactivatedState["acknowledgement_id"] = "ack-" + String(repeating: "8", count: 64)
        reactivatedState["overlay_display"] = try jsonObject(AgentOverlayDisplay(
            summaryKind: .start,
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "claude_app"
            )
        ))
        try applySnapshot(
            revision: "claude-reactivated-4",
            sessions: [unrelatedState, reactivatedState]
        )
        #expect(store.overlayAvailableBubbleContents.flatMap(\.sessions).contains {
            $0.source == .claudeCode && $0.eventType == .start
        })
    }

    @MainActor
    @Test
    func delayedRouteSuccessCannotDismissOrAcknowledgeANewerSessionEvent() async throws {
        let routeGate = AgentSessionRouteGate()
        let oldAcknowledgementID = "ack-" + String(repeating: "f", count: 64)
        let newAcknowledgementID = "ack-" + String(repeating: "0", count: 64)
        var acknowledgedIDs: [String] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { route in
                await routeGate.open(route)
            },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "agent.session.acknowledge",
                      let params = params as? [String: Any],
                      let acknowledgementID = params["acknowledgement_id"] as? String
                else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                acknowledgedIDs.append(acknowledgementID)
                return [
                    "acknowledged": true,
                    "acknowledgement_id": acknowledgementID,
                ]
            }
        )
        let oldSession = try applyRoutableSession(
            to: store,
            sessionID: "950e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: oldAcknowledgementID,
            capability: .agentHost,
            eventIDOverride: "route-race-old-event"
        )

        store.activateOverlaySession(oldSession)
        for _ in 0 ..< 1_000 where routeGate.openCount == 0 {
            await Task.yield()
        }
        #expect(routeGate.openCount == 1)

        _ = try applyRoutableSession(
            to: store,
            sessionID: "950e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: newAcknowledgementID,
            capability: .agentHost,
            eventIDOverride: "route-race-new-event",
            snapshotRevisionOverride: "route-race-new-snapshot"
        )
        #expect(store.overlayAvailableBubbleContents.first?.sessions.first?.id
            == oldSession.id)

        routeGate.complete(with: .openedAgentHost)
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        #expect(acknowledgedIDs.isEmpty)
        #expect(!store.overlayDismissedBubbleEventIDs.contains(oldSession.id))
        let visibleSession = try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
        #expect(visibleSession.id == oldSession.id)
    }

    @MainActor
    @Test
    func visuallyEquivalentNewSessionIdentityIsAcknowledgedWhenClicked() async throws {
        let oldAcknowledgementID = "ack-" + String(repeating: "1", count: 64)
        let newAcknowledgementID = "ack-" + String(repeating: "2", count: 64)
        var acknowledgedIDs: [String] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { _ in .openedAgentHost },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "agent.session.acknowledge",
                      let params = params as? [String: Any],
                      let acknowledgementID = params["acknowledgement_id"] as? String
                else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                acknowledgedIDs.append(acknowledgementID)
                return [
                    "acknowledged": true,
                    "acknowledgement_id": acknowledgementID,
                ]
            }
        )
        let oldSession = try applyRoutableSession(
            to: store,
            sessionID: "a50e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: oldAcknowledgementID,
            capability: .agentHost,
            eventIDOverride: "equivalent-route-old-event"
        )
        _ = try applyRoutableSession(
            to: store,
            sessionID: "a50e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: newAcknowledgementID,
            capability: .agentHost,
            eventIDOverride: "equivalent-route-new-event",
            snapshotRevisionOverride: "equivalent-route-new-snapshot"
        )
        let visuallyCachedSession = try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
        #expect(visuallyCachedSession.id == oldSession.id)
        #expect(visuallyCachedSession.eventID == oldSession.eventID)
        #expect(visuallyCachedSession.acknowledgementID == oldAcknowledgementID)

        store.activateOverlaySession(visuallyCachedSession)
        for _ in 0 ..< 1_000 where acknowledgedIDs.isEmpty {
            await Task.yield()
        }

        #expect(acknowledgedIDs == [newAcknowledgementID])
        #expect(store.overlayDismissedBubbleEventIDs.contains(oldSession.id))
        #expect(store.overlayAvailableBubbleContents.isEmpty)
    }

    @MainActor
    @Test
    func visuallyEquivalentNewSessionIdentityReceivesNavigationFailureNotice() async throws {
        var routeCount = 0
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { _ in
                routeCount += 1
                return .failed(.applicationLaunchFailed)
            },
            applicationAppearanceApplier: { _ in }
        )
        let sessionID = "b50e8400-e29b-41d4-a716-446655440000"
        let oldSession = try applyRoutableSession(
            to: store,
            sessionID: sessionID,
            acknowledgementID: "ack-" + String(repeating: "3", count: 64),
            capability: .agentHost,
            event: .waiting,
            eventIDOverride: "equivalent-notice-old-event"
        )
        _ = try applyRoutableSession(
            to: store,
            sessionID: sessionID,
            acknowledgementID: "ack-" + String(repeating: "4", count: 64),
            capability: .agentHost,
            event: .waiting,
            eventIDOverride: "equivalent-notice-current-event",
            snapshotRevisionOverride: "equivalent-notice-current-snapshot"
        )
        let visuallyCachedSession = try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
        #expect(visuallyCachedSession.eventID == oldSession.eventID)

        store.activateOverlaySession(visuallyCachedSession)
        for _ in 0 ..< 1_000 where routeCount == 0
            || store.overlayAvailableBubbleContents.first?.sessions.first?
                .navigationNotice == nil {
            await Task.yield()
        }

        #expect(routeCount == 1)
        #expect(store.overlayAvailableBubbleContents.first?.sessions.first?
            .navigationNotice == .failed)

        _ = try applyRoutableSession(
            to: store,
            sessionID: sessionID,
            acknowledgementID: "ack-" + String(repeating: "5", count: 64),
            capability: .agentHost,
            event: .waiting,
            eventIDOverride: "equivalent-notice-next-event",
            snapshotRevisionOverride: "equivalent-notice-next-snapshot"
        )
        #expect(store.overlayAvailableBubbleContents.first?.sessions.first?
            .navigationNotice == nil)
    }

    @MainActor
    @Test
    func staleAppRowRoutesAndAcknowledgesTheCurrentCLISession() async throws {
        var routes: [AgentSessionOpenRoute] = []
        var acknowledgedIDs: [String] = []
        let oldAcknowledgementID = "ack-" + String(repeating: "6", count: 64)
        let newAcknowledgementID = "ack-" + String(repeating: "7", count: 64)
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { route in
                routes.append(route)
                return .openedAgentHost
            },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "agent.session.acknowledge",
                      let params = params as? [String: Any],
                      let acknowledgementID = params["acknowledgement_id"] as? String
                else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                acknowledgedIDs.append(acknowledgementID)
                return [
                    "acknowledged": true,
                    "acknowledgement_id": acknowledgementID,
                ]
            }
        )
        let sessionID = "c50e8400-e29b-41d4-a716-446655440000"
        let staleAppSession = try applyRoutableSession(
            to: store,
            sessionID: sessionID,
            acknowledgementID: oldAcknowledgementID,
            capability: .agentHost,
            eventIDOverride: "cross-surface-app-event"
        )
        _ = try applyRoutableSession(
            to: store,
            sessionID: sessionID,
            acknowledgementID: newAcknowledgementID,
            capability: .agentHost,
            eventIDOverride: "cross-surface-cli-event",
            snapshotRevisionOverride: "cross-surface-cli-snapshot",
            navigationOverride: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "cli_terminal",
                terminalApp: "terminal"
            )
        )
        #expect(staleAppSession.surfaceKind == .app)
        #expect(store.overlayAvailableBubbleContents.first?.sessions.first?
            .surfaceKind == .cli)

        store.activateOverlaySession(staleAppSession)
        for _ in 0 ..< 1_000 where acknowledgedIDs.isEmpty {
            await Task.yield()
        }

        #expect(routes.count == 1)
        guard case let .application(bundleIdentifiers, _) = routes.first else {
            Issue.record("Expected the current CLI terminal application route")
            return
        }
        #expect(bundleIdentifiers == ["com.apple.Terminal"])
        #expect(acknowledgedIDs == [newAcknowledgementID])
        #expect(store.overlayAvailableBubbleContents.isEmpty)
    }

    @MainActor
    @Test
    func rejectedDeepLinkOpensSameSurfaceHostButKeepsRowAndAck() async throws {
        let acknowledgementID = "ack-" + String(repeating: "b", count: 64)
        var routes: [AgentSessionOpenRoute] = []
        var acknowledgementCount = 0
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { route in
                routes.append(route)
                return switch route {
                case .url:
                    routes.count >= 3
                        ? .openedExactSession
                        : .failed(.urlOpenRejected)
                case .application: .openedAgentHost
                }
            },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, _, _ in
                guard method == "agent.session.acknowledge" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                acknowledgementCount += 1
                return [
                    "acknowledged": true,
                    "acknowledgement_id": acknowledgementID,
                ]
            }
        )
        let session = try applyRoutableSession(
            to: store,
            sessionID: "550e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: acknowledgementID,
            capability: .exactSession,
            event: .waiting
        )

        store.activateOverlaySession(session)
        for _ in 0 ..< 1_000 where routes.count < 2 {
            await Task.yield()
        }
        await Task.yield()

        #expect(routes.count == 2)
        guard routes.count == 2 else { return }
        if case let .url(url) = routes[0] {
            #expect(url.scheme == "codex")
        } else {
            Issue.record("Expected the exact route first")
        }
        if case let .application(bundleIdentifiers, _) = routes[1] {
            #expect(bundleIdentifiers == ["com.openai.codex"])
        } else {
            Issue.record("Expected the same ChatGPT surface fallback")
        }
        #expect(acknowledgementCount == 0)
        #expect(!store.overlayDismissedBubbleEventIDs.contains(session.id))
        let retained = try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
        #expect(retained.navigationNotice == .degradedToHost)
        #expect(retained.primaryDetailText == APCLocalization.text(
            .overlaySessionNavigationDegraded
        ))
        #expect(retained.accessibilityLabel.contains(retained.primaryDetailText))

        store.activateOverlaySession(retained)
        for _ in 0 ..< 1_000 where routes.count < 3
            || store.overlayAvailableBubbleContents.first?.sessions.first?
                .navigationNotice != nil {
            await Task.yield()
        }
        #expect(routes.count == 3)
        #expect(store.overlayAvailableBubbleContents.first?.sessions.first?
            .navigationNotice == nil)
        #expect(!store.overlayDismissedBubbleEventIDs.contains(session.id))
    }

    @MainActor
    @Test
    func urlAndMissingFallbackFailureKeepCompletedSessionUnacknowledged() async throws {
        let acknowledgementID = "ack-" + String(repeating: "c", count: 64)
        var routes: [AgentSessionOpenRoute] = []
        var acknowledgementCount = 0
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { route in
                routes.append(route)
                return switch route {
                case .url: .failed(.urlOpenRejected)
                case .application: .failed(.applicationUnavailable)
                }
            },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, _, _ in
                if method == "agent.session.acknowledge" {
                    acknowledgementCount += 1
                }
                throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
            }
        )
        let session = try applyRoutableSession(
            to: store,
            sessionID: "650e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: acknowledgementID,
            capability: .exactSession
        )

        store.activateOverlaySession(session)
        for _ in 0 ..< 1_000 where routes.count < 2 {
            await Task.yield()
        }

        #expect(routes.count == 2)
        #expect(acknowledgementCount == 0)
        #expect(!store.overlayDismissedBubbleEventIDs.contains(session.id))
        let retained = try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
        #expect(retained.navigationNotice == .failed)
        #expect(retained.primaryDetailText == APCLocalization.text(
            .overlaySessionNavigationFailed
        ))
        let refreshed = try applyRoutableSession(
            to: store,
            sessionID: "650e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: acknowledgementID,
            capability: .exactSession,
            eventIDOverride: "new-event-after-navigation-failure"
        )
        #expect(refreshed.navigationNotice == nil)
    }

    @MainActor
    @Test
    func applicationLaunchCompletionFailureKeepsSessionAndAcknowledgement() async throws {
        let acknowledgementID = "ack-" + String(repeating: "d", count: 64)
        var routes: [AgentSessionOpenRoute] = []
        var acknowledgementCount = 0
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { route in
                routes.append(route)
                return .failed(.applicationLaunchFailed)
            },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, _, _ in
                if method == "agent.session.acknowledge" {
                    acknowledgementCount += 1
                }
                throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
            }
        )
        let session = try applyRoutableSession(
            to: store,
            sessionID: "750e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: acknowledgementID,
            capability: .agentHost
        )

        store.activateOverlaySession(session)
        for _ in 0 ..< 1_000 where routes.isEmpty {
            await Task.yield()
        }

        #expect(routes.count == 1)
        #expect(acknowledgementCount == 0)
        #expect(!store.overlayDismissedBubbleEventIDs.contains(session.id))
        let retained = try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
        #expect(retained.navigationNotice == .failed)
    }

    @MainActor
    @Test
    func unavailableCompletedSessionNeverRoutesDismissesOrAcknowledges() async throws {
        var routeCount = 0
        var acknowledgementCount = 0
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            agentSessionRouteOpener: { _ in
                routeCount += 1
                return .openedAgentHost
            },
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, _, _ in
                if method == "agent.session.acknowledge" {
                    acknowledgementCount += 1
                }
                throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
            }
        )
        let session = try applyRoutableSession(
            to: store,
            sessionID: "850e8400-e29b-41d4-a716-446655440000",
            acknowledgementID: "ack-" + String(repeating: "e", count: 64),
            capability: .unavailable
        )

        store.activateOverlaySession(session)
        await Task.yield()

        #expect(routeCount == 0)
        #expect(acknowledgementCount == 0)
        #expect(!store.overlayDismissedBubbleEventIDs.contains(session.id))
        let retained = try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
        #expect(retained.navigationNotice == .unavailable)
    }

    @MainActor
    @Test
    func debouncedOverlayPlacementBlocksHandoffUntilTheSaveFinishes() async throws {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError(
                        "Unexpected test RPC: \(method)"
                    )
                }
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 2
                )
            }
        )
        try store.applyStateSnapshot([
            "revision": "placement-1",
            "overlay_placement_revision": "1",
            "behavior": try jsonObject(BehaviorSettings()),
            "behavior_revision": "1",
            "overlay_placement": try jsonObject(OverlayPlacement()),
            "pets": [],
            "events": [],
            "connections": [],
        ])

        for _ in 0..<100 where !store.isSafeForAppUpdateHandoff {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.isSafeForAppUpdateHandoff)

        store.moveOverlayPet(
            to: CGPoint(x: 500, y: 400),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            commit: true
        )
        #expect(!store.isSafeForAppUpdateHandoff)

        for _ in 0..<100 where !store.isSafeForAppUpdateHandoff {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.isSafeForAppUpdateHandoff)
    }

    @MainActor
    @Test
    func dragSamplesWriteNothingUntilReleaseThenSaveExactlyOnce() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = (
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.stringValue ?? "main"
        let start = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        var requestCount = 0
        var savedParams: [String: Any]?
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requestCount += 1
                savedParams = params as? [String: Any]
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 11
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 10,
            placement: OverlayPlacement(
                x: start.x,
                y: start.y,
                displayWidthPt: 112,
                displayId: displayID
            )
        ))

        let interactionID = UUID()
        let finalCenter = CGPoint(x: start.x + 50, y: start.y + 30)
        store.beginOverlayPetDrag(interactionID: interactionID)
        for sample in 1 ... 500 {
            let progress = CGFloat(sample) / 500
            store.presentOverlayPetDrag(
                at: CGPoint(
                    x: start.x + 50 * progress,
                    y: start.y + 30 * progress
                ),
                visibleFrame: screen.visibleFrame,
                interactionID: interactionID
            )
        }

        #expect(requestCount == 0)
        store.commitOverlayPetDrag(
            at: finalCenter,
            visibleFrame: screen.visibleFrame,
            interactionID: interactionID
        )
        for _ in 0 ..< 100 where requestCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(requestCount == 1)
        #expect(savedParams?["display_width_pt"] as? Double == 112)
        #expect(abs((savedParams?["x"] as? Double ?? 0) - finalCenter.x) < 0.001)
        #expect(abs((savedParams?["y"] as? Double ?? 0) - finalCenter.y) < 0.001)
    }

    @MainActor
    @Test
    func lostPointerCaptureCommitsTheLastPresentedCenterExactlyOnce() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = (
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.stringValue ?? "main"
        let start = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let presented = CGPoint(x: start.x + 48, y: start.y - 32)
        var requestCount = 0
        var savedParams: [String: Any]?
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requestCount += 1
                savedParams = params as? [String: Any]
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 31
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 30,
            placement: OverlayPlacement(
                x: start.x,
                y: start.y,
                displayWidthPt: 112,
                displayId: displayID
            )
        ))

        let interactionID = UUID()
        store.beginOverlayPetDrag(interactionID: interactionID)
        store.presentOverlayPetDrag(
            at: presented,
            visibleFrame: screen.visibleFrame,
            interactionID: interactionID
        )
        store.reconcileOverlayPointerInteractions(pressedMouseButtons: 0)
        for _ in 0 ..< 100 where requestCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(!store.overlayPetDragInProgress)
        #expect(store.overlayPetScreenCenter == presented)
        #expect(store.overlayPresentedPetScreenCenter == presented)
        #expect(requestCount == 1)
        #expect(abs((savedParams?["x"] as? Double ?? 0) - presented.x) < 0.001)
        #expect(abs((savedParams?["y"] as? Double ?? 0) - presented.y) < 0.001)
    }

    @MainActor
    @Test
    func normalMouseUpWinsTheFallbackGraceWindowExactlyOnce() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = screenDisplayID(screen)
        let start = CGPoint(
            x: screen.visibleFrame.midX,
            y: screen.visibleFrame.midY
        )
        let presented = CGPoint(x: start.x + 40, y: start.y + 24)
        var requestCount = 0
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError(
                        "Unexpected test RPC: \(method)"
                    )
                }
                requestCount += 1
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 41
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 40,
            placement: placement(at: start, displayID: displayID)
        ))

        let interactionID = UUID()
        store.beginOverlayPetDrag(interactionID: interactionID)
        store.presentOverlayPetDrag(
            at: presented,
            visibleFrame: screen.visibleFrame,
            interactionID: interactionID
        )
        store.reconcileOverlayPointerInteractions(pressedMouseButtons: 0)
        store.commitOverlayPetDrag(
            at: presented,
            visibleFrame: screen.visibleFrame,
            interactionID: interactionID
        )
        for _ in 0 ..< 1_000 where requestCount == 0 {
            await Task.yield()
        }
        for _ in 0 ..< 100 { await Task.yield() }

        #expect(requestCount == 1)
        #expect(!store.overlayPetDragInProgress)
        #expect(store.overlayPetScreenCenter == presented)
    }

    @MainActor
    @Test(arguments: [
        (20.0, 500.0),
        (300.0, 16.0),
    ])
    func releasedPetHasAtMostHalfAPointDriftAfter500Milliseconds(
        pointerTravel: Double,
        nominalDragDurationMS: Double
    ) async throws {
        let screen = try #require(NSScreen.main)
        let displayID = (
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.stringValue ?? "main"
        let start = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let release = CGPoint(
            x: start.x + min(CGFloat(pointerTravel), screen.visibleFrame.width / 4),
            y: start.y + 18
        )
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 41
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 40,
            placement: OverlayPlacement(
                x: start.x,
                y: start.y,
                displayWidthPt: 112,
                displayId: displayID
            )
        ))

        // The two cases represent a slow 500 ms gesture and a high-speed
        // 16 ms flick. Release never transfers velocity into another owner.
        #expect(nominalDragDurationMS > 0)
        let interactionID = UUID()
        store.beginOverlayPetDrag(interactionID: interactionID)
        store.presentOverlayPetDrag(
            at: release,
            visibleFrame: screen.visibleFrame,
            interactionID: interactionID
        )
        store.commitOverlayPetDrag(
            at: release,
            visibleFrame: screen.visibleFrame,
            interactionID: interactionID
        )
        let committed = store.overlayPresentedPetScreenCenter

        try await Task.sleep(for: .milliseconds(500))

        #expect(hypot(
            store.overlayPresentedPetScreenCenter.x - committed.x,
            store.overlayPresentedPetScreenCenter.y - committed.y
        ) <= 0.5)
        #expect(hypot(
            store.overlayPetScreenCenter.x - committed.x,
            store.overlayPetScreenCenter.y - committed.y
        ) <= 0.5)
    }

    @MainActor
    @Test
    func placementWorkerExhaustsAtFiveThenExplicitRetryRecoversLatest() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = (
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.stringValue ?? "main"
        let start = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let stale = CGPoint(x: start.x + 20, y: start.y + 10)
        let latest = CGPoint(x: start.x + 70, y: start.y + 35)
        let sleeper = OverlayPlacementRetrySleeperProbe()
        let journal = OverlayPlacementJournalMemoryProbe()
        var requests: [[String: Any]] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            overlayPlacementRetrySleeper: { duration in
                await sleeper.sleep(duration)
            },
            overlayPlacementJournalStore: journal.store,
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requests.append(try #require(params as? [String: Any]))
                if requests.count <= 5 {
                    throw PetCoreClientError.rpcError("synthetic placement outage")
                }
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 51
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 50,
            placement: OverlayPlacement(
                x: start.x,
                y: start.y,
                displayWidthPt: 112,
                displayId: displayID
            )
        ))

        // Both commits are queued before the worker can run. The superseded
        // value must be skipped and never revived by a delayed retry.
        store.moveOverlayPet(
            to: stale,
            visibleFrame: screen.visibleFrame,
            commit: true
        )
        store.moveOverlayPet(
            to: latest,
            visibleFrame: screen.visibleFrame,
            commit: true
        )
        #expect(!store.isSafeForAppUpdateHandoff)

        for expectedWaitCount in 1 ... 4 {
            for _ in 0 ..< 1_000 {
                let waitCount = await sleeper.waitCount
                if requests.count == expectedWaitCount,
                   waitCount == expectedWaitCount {
                    break
                }
                await Task.yield()
            }
            #expect(requests.count == expectedWaitCount)
            let waitCount = await sleeper.waitCount
            #expect(waitCount == expectedWaitCount)
            #expect(!store.isSafeForAppUpdateHandoff)
            await sleeper.resumeNext()
        }

        for _ in 0 ..< 1_000 where requests.count < 5 {
            await Task.yield()
        }

        #expect(requests.count == 5)
        #expect(!store.isSafeForAppUpdateHandoff)
        #expect(journal.entry != nil)
        let delays = await sleeper.delays
        #expect(delays == [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
        ])
        #expect(requests.allSatisfy { request in
            abs((request["x"] as? Double ?? 0) - latest.x) < 0.001
                && abs((request["y"] as? Double ?? 0) - latest.y) < 0.001
        })

        // Ordinary snapshots and a long virtual idle window cannot revive an
        // exhausted generation.
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 50,
            placement: OverlayPlacement(
                x: start.x,
                y: start.y,
                displayWidthPt: 112,
                displayId: displayID
            )
        ))
        for _ in 0 ..< 1_000 { await Task.yield() }
        #expect(requests.count == 5)
        #expect(await sleeper.waitCount == 4)

        store.retryPendingOverlayPlacementSave()
        for _ in 0 ..< 1_000 where requests.count < 6
            || !store.isSafeForAppUpdateHandoff {
            await Task.yield()
        }
        #expect(requests.count == 6)
        #expect(store.isSafeForAppUpdateHandoff)
        #expect(journal.entry == nil)
    }

    @MainActor
    @Test
    func consecutiveConflictsConsumeOneSharedFiveAttemptBudget() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = screenDisplayID(screen)
        let start = CGPoint(
            x: screen.visibleFrame.midX,
            y: screen.visibleFrame.midY
        )
        let latest = CGPoint(x: start.x + 72, y: start.y + 36)
        let sleeper = OverlayPlacementRetrySleeperProbe()
        let journal = OverlayPlacementJournalMemoryProbe()
        var requests: [[String: Any]] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            overlayPlacementRetrySleeper: { duration in
                await sleeper.sleep(duration)
            },
            overlayPlacementJournalStore: journal.store,
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError(
                        "Unexpected test RPC: \(method)"
                    )
                }
                requests.append(try #require(params as? [String: Any]))
                return try placementUpdateConflict(
                    placement: placement(at: start, displayID: displayID),
                    placementRevision: 70 + UInt64(requests.count),
                    intent: nil
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 70,
            placement: placement(at: start, displayID: displayID)
        ))
        store.moveOverlayPet(
            to: latest,
            visibleFrame: screen.visibleFrame,
            commit: true
        )

        for expectedWaitCount in 1 ... 4 {
            for _ in 0 ..< 1_000 {
                if requests.count == expectedWaitCount,
                   await sleeper.waitCount == expectedWaitCount {
                    break
                }
                await Task.yield()
            }
            await sleeper.resumeNext()
        }
        for _ in 0 ..< 1_000 where requests.count < 5 {
            await Task.yield()
        }
        for _ in 0 ..< 1_000 { await Task.yield() }

        #expect(requests.count == 5)
        #expect(requests.map { $0["expected_revision"] as? String }
            == ["70", "71", "72", "73", "74"])
        #expect(await sleeper.delays == [
            .milliseconds(250),
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
        ])
        #expect(journal.entry != nil)
        #expect(!store.isSafeForAppUpdateHandoff)
    }

    @MainActor
    @Test
    func thirdAttemptSuccessStopsRetriesAndRemainsSilent() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = screenDisplayID(screen)
        let start = CGPoint(
            x: screen.visibleFrame.midX,
            y: screen.visibleFrame.midY
        )
        let latest = CGPoint(x: start.x + 52, y: start.y - 28)
        let sleeper = OverlayPlacementRetrySleeperProbe()
        let journal = OverlayPlacementJournalMemoryProbe()
        var requestCount = 0
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            overlayPlacementRetrySleeper: { duration in
                await sleeper.sleep(duration)
            },
            overlayPlacementJournalStore: journal.store,
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError(
                        "Unexpected test RPC: \(method)"
                    )
                }
                requestCount += 1
                if requestCount < 3 {
                    throw PetCoreClientError.rpcError("synthetic transport")
                }
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 91
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 90,
            placement: placement(at: start, displayID: displayID)
        ))
        store.moveOverlayPet(
            to: latest,
            visibleFrame: screen.visibleFrame,
            commit: true
        )

        for expectedAttempt in 1 ... 2 {
            for _ in 0 ..< 1_000 {
                let waitCount = await sleeper.waitCount
                if requestCount == expectedAttempt,
                   waitCount == expectedAttempt {
                    break
                }
                await Task.yield()
            }
            await sleeper.resumeNext()
        }
        for _ in 0 ..< 1_000 where requestCount < 3
            || !store.isSafeForAppUpdateHandoff {
            await Task.yield()
        }

        #expect(requestCount == 3)
        #expect(await sleeper.delays == [
            .milliseconds(250),
            .milliseconds(500),
        ])
        #expect(store.isSafeForAppUpdateHandoff)
        #expect(journal.entry == nil)

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 91,
            placement: placement(at: latest, displayID: displayID)
        ))
        for _ in 0 ..< 10_000 { await Task.yield() }
        #expect(requestCount == 3)
    }

    @MainActor
    @Test
    func explicitIntentConsumesOnceAndPendingBlocksEverySnapshotUntilAck() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = screenDisplayID(screen)
        let initial = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let reset = CGPoint(x: initial.x + 40, y: initial.y + 24)
        let blocked = CGPoint(x: initial.x - 40, y: initial.y - 24)
        let gate = OverlayPlacementRequestGate()
        var requests: [[String: Any]] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requests.append(try #require(params as? [String: Any]))
                await gate.suspend()
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 12
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 10,
            placement: placement(at: initial, displayID: displayID)
        ))

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 11,
            placement: placement(at: reset, displayID: displayID),
            intent: .reset
        ))
        await gate.waitUntilEntered()

        #expect(requests.count == 1)
        #expect(requests[0]["expected_revision"] as? String == "11")
        #expect(store.overlayPetScreenCenter == reset)
        #expect(!store.isSafeForAppUpdateHandoff)

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 12,
            placement: placement(at: blocked, displayID: displayID),
            intent: .externalReposition
        ))
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 99,
            placement: placement(at: blocked, displayID: displayID)
        ))
        #expect(store.overlayPetScreenCenter == reset)
        #expect(requests.count == 1)

        await gate.resume()
        for _ in 0 ..< 1_000 where !store.isSafeForAppUpdateHandoff {
            await Task.yield()
        }
        #expect(store.isSafeForAppUpdateHandoff)

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 100,
            placement: placement(at: blocked, displayID: displayID)
        ))
        #expect(store.overlayPetScreenCenter == reset)
        #expect(requests.count == 1)
    }

    @MainActor
    @Test
    func newerExplicitConflictSupersedesInFlightConsumeAndIsConsumed() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = screenDisplayID(screen)
        let initial = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let first = CGPoint(x: initial.x + 34, y: initial.y + 18)
        let latest = CGPoint(x: initial.x - 46, y: initial.y - 20)
        let latestPlacement = placement(at: latest, displayID: displayID)
        let gate = OverlayPlacementRequestGate()
        let journal = OverlayPlacementJournalMemoryProbe()
        var requests: [[String: Any]] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            overlayPlacementRetrySleeper: { _ in },
            overlayPlacementJournalStore: journal.store,
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requests.append(try #require(params as? [String: Any]))
                if requests.count == 1 {
                    await gate.suspend()
                    return try placementUpdateConflict(
                        placement: latestPlacement,
                        placementRevision: 12,
                        intent: .externalReposition
                    )
                }
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 13
                )
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 10,
            placement: placement(at: initial, displayID: displayID)
        ))
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 11,
            placement: placement(at: first, displayID: displayID),
            intent: .reset
        ))
        await gate.waitUntilEntered()

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 12,
            placement: latestPlacement,
            intent: .externalReposition
        ))
        #expect(store.overlayPetScreenCenter == first)
        await gate.resume()

        for _ in 0 ..< 2_000 where requests.count < 2
            || !store.isSafeForAppUpdateHandoff {
            await Task.yield()
        }
        #expect(requests.count == 2)
        let secondRequest = try #require(requests.dropFirst().first)
        #expect(requests[0]["expected_revision"] as? String == "11")
        #expect(secondRequest["expected_revision"] as? String == "12")
        #expect(abs((secondRequest["x"] as? Double ?? 0) - latest.x) < 0.001)
        #expect(abs((secondRequest["y"] as? Double ?? 0) - latest.y) < 0.001)
        #expect(store.overlayPetScreenCenter == latest)
        #expect(store.isSafeForAppUpdateHandoff)
        #expect(journal.entry == nil)
    }

    @MainActor
    @Test
    func consecutiveLocalCommitsIgnoreOldResponsesAndPersistOnlyLatest() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = screenDisplayID(screen)
        let initial = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let first = CGPoint(x: initial.x + 28, y: initial.y + 14)
        let latest = CGPoint(x: initial.x + 72, y: initial.y + 32)
        let gate = OverlayPlacementRequestGate()
        let journal = OverlayPlacementJournalMemoryProbe()
        var requests: [[String: Any]] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            overlayPlacementRetrySleeper: { _ in },
            overlayPlacementJournalStore: journal.store,
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requests.append(try #require(params as? [String: Any]))
                switch requests.count {
                case 1:
                    await gate.suspend()
                    return try placementUpdateSuccess(
                        params,
                        placementRevision: 21
                    )
                case 2:
                    return try placementUpdateConflict(
                        placement: placement(at: first, displayID: displayID),
                        placementRevision: 22,
                        intent: nil
                    )
                default:
                    return try placementUpdateSuccess(
                        params,
                        placementRevision: 23
                    )
                }
            }
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 20,
            placement: placement(at: initial, displayID: displayID)
        ))
        store.moveOverlayPet(
            to: first,
            visibleFrame: screen.visibleFrame,
            commit: true
        )
        await gate.waitUntilEntered()
        store.moveOverlayPet(
            to: latest,
            visibleFrame: screen.visibleFrame,
            commit: true
        )
        let latestIdentity = try #require(journal.entry?.interactionID)
        await gate.resume()

        for _ in 0 ..< 2_000 where requests.count < 3
            || !store.isSafeForAppUpdateHandoff {
            await Task.yield()
        }
        #expect(requests.count == 3)
        #expect(requests.map { $0["expected_revision"] as? String }
            == ["20", "20", "22"])
        #expect(abs((requests[1]["x"] as? Double ?? 0) - latest.x) < 0.001)
        #expect(abs((requests[2]["x"] as? Double ?? 0) - latest.x) < 0.001)
        #expect(store.overlayPetScreenCenter == latest)
        #expect(journal.entry == nil)
        #expect(journal.savedEntries.last?.interactionID == latestIdentity)
        #expect(!journal.removalAttempts.isEmpty)
        #expect(journal.removalAttempts.allSatisfy { attempt in
            attempt.expectedInteractionID == latestIdentity
                && attempt.currentInteractionID == latestIdentity
        })
    }

    @MainActor
    @Test
    func pendingJournalRecoversLastReleaseAndClearsAfterAck() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = screenDisplayID(screen)
        let initial = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let recovered = CGPoint(x: initial.x + 66, y: initial.y + 30)
        let journal = OverlayPlacementJournalMemoryProbe(entry:
            OverlayPlacementJournalEntry(
                interactionID: UUID(),
                localRevision: 1,
                placement: placement(at: recovered, displayID: displayID),
                baseRemoteRevision: 30
            )
        )
        var requests: [[String: Any]] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            overlayPlacementJournalStore: journal.store,
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requests.append(try #require(params as? [String: Any]))
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 31
                )
            }
        )

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 30,
            placement: placement(at: initial, displayID: displayID)
        ))
        #expect(store.overlayPetScreenCenter == recovered)
        for _ in 0 ..< 1_000 where requests.isEmpty
            || !store.isSafeForAppUpdateHandoff {
            await Task.yield()
        }

        #expect(requests.count == 1)
        #expect(requests[0]["expected_revision"] as? String == "30")
        #expect(abs((requests[0]["x"] as? Double ?? 0) - recovered.x) < 0.001)
        #expect(journal.entry == nil)
        #expect(store.isSafeForAppUpdateHandoff)
    }

    @MainActor
    @Test
    func newerExplicitSnapshotWinsOverStaleJournal() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = screenDisplayID(screen)
        let initial = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let stale = CGPoint(x: initial.x + 60, y: initial.y + 30)
        let latest = CGPoint(x: initial.x - 54, y: initial.y - 26)
        let staleEntry = OverlayPlacementJournalEntry(
            interactionID: UUID(),
            localRevision: 1,
            placement: placement(at: stale, displayID: displayID),
            baseRemoteRevision: 30
        )
        let journal = OverlayPlacementJournalMemoryProbe(entry: staleEntry)
        var requests: [[String: Any]] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            overlayPlacementJournalStore: journal.store,
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requests.append(try #require(params as? [String: Any]))
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 32
                )
            }
        )

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 31,
            placement: placement(at: latest, displayID: displayID),
            intent: .reset
        ))
        for _ in 0 ..< 1_000 where requests.isEmpty
            || !store.isSafeForAppUpdateHandoff {
            await Task.yield()
        }

        #expect(store.overlayPetScreenCenter == latest)
        #expect(requests.count == 1)
        #expect(requests[0]["expected_revision"] as? String == "31")
        #expect(abs((requests[0]["x"] as? Double ?? 0) - latest.x) < 0.001)
        #expect(journal.savedEntries.contains { $0.placement.x == latest.x })
        #expect(journal.entry == nil)
    }

    @MainActor
    @Test
    func ordinaryNewerSnapshotCannotReplaceLocalAuthorityButExplicitResetCan() async throws {
        let screen = try #require(NSScreen.main)
        let displayID = (
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.stringValue ?? "main"
        let initial = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        let local = CGPoint(x: initial.x + 44, y: initial.y + 26)
        let remote = CGPoint(x: initial.x - 44, y: initial.y - 26)
        var requests: [[String: Any]] = []
        let store = AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in },
            petCoreRequestOverride: { method, params, _ in
                guard method == "overlay.placement.update" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                requests.append(try #require(params as? [String: Any]))
                if requests.count == 1 {
                    throw PetCoreClientError.rpcError("synthetic placement failure")
                }
                return try placementUpdateSuccess(
                    params,
                    placementRevision: 21
                )
            }
        )
        let initialPlacement = OverlayPlacement(
            x: initial.x,
            y: initial.y,
            displayWidthPt: 112,
            displayId: displayID
        )
        try store.applyStateSnapshot(try placementSnapshot(
            revision: 20,
            placement: initialPlacement
        ))

        let interactionID = UUID()
        store.beginOverlayPetDrag(interactionID: interactionID)
        store.presentOverlayPetDrag(
            at: local,
            visibleFrame: screen.visibleFrame,
            interactionID: interactionID
        )
        store.commitOverlayPetDrag(
            at: local,
            visibleFrame: screen.visibleFrame,
            interactionID: interactionID
        )
        for _ in 0 ..< 100 where requests.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests.count == 1)

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 20,
            placement: initialPlacement
        ))
        #expect(store.overlayPetScreenCenter == local)

        for _ in 0 ..< 200 where requests.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requests.count == 2)
        #expect(requests[0]["x"] as? Double == requests[1]["x"] as? Double)
        #expect(requests[0]["y"] as? Double == requests[1]["y"] as? Double)
        #expect(
            requests[0]["display_width_pt"] as? Double
                == requests[1]["display_width_pt"] as? Double
        )

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 22,
            placement: OverlayPlacement(
                x: remote.x,
                y: remote.y,
                displayWidthPt: 112,
                displayId: displayID
            )
        ))
        #expect(store.overlayPetScreenCenter == local)

        try store.applyStateSnapshot(try placementSnapshot(
            revision: 23,
            placement: OverlayPlacement(
                x: remote.x,
                y: remote.y,
                displayWidthPt: 112,
                displayId: displayID
            ),
            intent: .reset
        ))
        #expect(store.overlayPetScreenCenter == remote)
    }

    @MainActor
    @Test
    func unknownOverlayPlacementIntentFailsClosed() throws {
        let store = makeStore()
        var snapshot = try placementSnapshot(
            revision: 1,
            placement: OverlayPlacement()
        )
        snapshot["overlay_placement_intent"] = "future_reposition"

        #expect(throws: DecodingError.self) {
            try store.applyStateSnapshot(snapshot)
        }
    }

    @MainActor
    @Test
    func placementRevisionMustBePresentCanonicalDecimalString() throws {
        let store = makeStore()
        var missing = try placementSnapshot(
            revision: 1,
            placement: OverlayPlacement()
        )
        missing.removeValue(forKey: "overlay_placement_revision")
        #expect(throws: DecodingError.self) {
            try store.applyStateSnapshot(missing)
        }

        for invalid in ["", "01", "-1", "18446744073709551616"] {
            var malformed = try placementSnapshot(
                revision: 1,
                placement: OverlayPlacement()
            )
            malformed["overlay_placement_revision"] = invalid
            #expect(throws: PetCoreClientError.self) {
                try store.applyStateSnapshot(malformed)
            }
        }
    }

    @MainActor
    private func makeStore() -> AppStore {
        AppStore(
            bootstrapHooks: testBootstrapHooks(),
            applicationAppearanceApplier: { _ in }
        )
    }

    @MainActor
    private func testBootstrapHooks() -> AppStoreBootstrapHooks {
        AppStoreBootstrapHooks(
            ensureRunning: { .alreadyHealthy },
            recover: { .alreadyHealthy },
            refreshSnapshot: { _ in },
            onReady: { _ in }
        )
    }

    private func placementSnapshot(
        revision: UInt64,
        placement: OverlayPlacement,
        intent: OverlayPlacementRemoteIntent? = nil
    ) throws -> [String: Any] {
        var snapshot: [String: Any] = [
            "revision": String(revision),
            "overlay_placement_revision": String(revision),
            "behavior": try jsonObject(BehaviorSettings()),
            "behavior_revision": "1",
            "overlay_placement": try jsonObject(placement),
            "pets": [],
            "events": [],
            "connections": [],
        ]
        if let intent {
            snapshot["overlay_placement_intent"] = intent.rawValue
        }
        return snapshot
    }

    private func makeState(
        source: AgentSource,
        session: String,
        event: AgentEventKind,
        activatedSecond: Int
    ) -> ActiveAgentState {
        let summary: AgentOverlaySummaryKind = switch event {
        case .start: .start
        case .thinking: .thinking
        case .plan: .plan
        case .tool: .tool
        case .waiting: .needsInput
        case .done: .done
        case .failed: .failed
        }
        let timestamp = String(format: "2026-07-22T00:00:%02dZ", activatedSecond)
        return ActiveAgentState(
            state: event.petState,
            officialStatus: "running",
            source: source,
            sessionID: session,
            sessionActive: true,
            sourceSessionSequence: UInt64(activatedSecond),
            priority: 300,
            leaseSeconds: nil,
            expiresAt: nil,
            sessionActivatedAt: timestamp,
            event: AgentEvent(
                id: "event-\(session)",
                source: source,
                sessionID: session,
                eventType: event,
                title: event.title,
                createdAt: timestamp
            ),
            latestMessage: nil,
            latestUserMessage: nil,
            sessionTitle: nil,
            sessionMessage: nil,
            sessionUserMessage: nil,
            sessionActivity: nil,
            overlayDisplay: AgentOverlayDisplay(summaryKind: summary)
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func screenDisplayID(_ screen: NSScreen) -> String {
        (
            screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        )?.stringValue ?? "main"
    }

    private func placement(
        at center: CGPoint,
        displayID: String,
        displayWidthPt: Double = 112
    ) -> OverlayPlacement {
        OverlayPlacement(
            x: center.x,
            y: center.y,
            displayWidthPt: displayWidthPt,
            displayId: displayID
        )
    }

    @MainActor
    private func applyRoutableSession(
        to store: AppStore,
        sessionID: String,
        acknowledgementID: String,
        capability: NavigationCapability,
        event: AgentEventKind = .done,
        eventIDOverride: String? = nil,
        snapshotRevisionOverride: String? = nil,
        navigationOverride: AgentSessionNavigation? = nil
    ) throws -> OverlaySessionContent {
        var state = try jsonObject(makeState(
            source: .codex,
            session: sessionID,
            event: event,
            activatedSecond: 1
        ))
        state["acknowledgement_id"] = acknowledgementID
        if let eventIDOverride,
           var eventObject = state["event"] as? [String: Any] {
            eventObject["id"] = eventIDOverride
            state["event"] = eventObject
        }
        state["overlay_display"] = try jsonObject(AgentOverlayDisplay(
            summaryKind: event == .waiting ? .needsInput : .done,
            navigation: navigationOverride ?? AgentSessionNavigation(
                capability: capability,
                sessionOpen: true,
                surface: "chatgpt_app",
                routableSessionID: capability == .exactSession ? sessionID : nil
            )
        ))
        let screen = try #require(NSScreen.main)
        let center = OverlayGeometry.defaultPetScreenCenter(
            in: screen.visibleFrame,
            displayWidthPt: 112
        )
        try store.applyStateSnapshot([
            "revision": snapshotRevisionOverride ?? "route-\(sessionID)",
            "overlay_placement_revision": "1",
            "overlay_placement": try jsonObject(placement(
                at: center,
                displayID: screenDisplayID(screen)
            )),
            "behavior": try jsonObject(BehaviorSettings(
                sessionGroupDisplay: .expanded
            )),
            "behavior_revision": "1",
            "pets": [],
            "active_agent_sessions": [state],
            "active_agent_sessions_omitted_count": 0,
            "overlay_visibility": try jsonObject(OverlayVisibility()),
            "events": [],
            "recent_events": [],
            "connections": [],
        ])
        return try #require(
            store.overlayAvailableBubbleContents.first?.sessions.first
        )
    }

    private func placementUpdateConflict(
        placement: OverlayPlacement,
        placementRevision: UInt64,
        intent: OverlayPlacementRemoteIntent?
    ) throws -> [String: Any] {
        [
            "ok": false,
            "conflict": true,
            "overlay_placement_revision": String(placementRevision),
            "overlay_placement": try jsonObject(placement),
            "overlay_placement_intent": intent.map { $0.rawValue as Any }
                ?? NSNull(),
        ]
    }

    private func jsonArray<T: Encodable>(_ value: T) throws -> [Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [Any])
    }

    private func placementUpdateSuccess(
        _ params: Any,
        placementRevision: UInt64
    ) throws -> [String: Any] {
        var placement = try #require(params as? [String: Any])
        let expectedRevision = try #require(
            placement.removeValue(forKey: "expected_revision") as? String
        )
        let expected = try #require(
            OverlayPlacementRevisionCodec.parse(expectedRevision)
        )
        let resolvedRevision = max(placementRevision, expected &+ 1)
        return [
            "ok": true,
            "revision": "state-\(resolvedRevision)",
            "overlay_placement_revision": String(resolvedRevision),
            "overlay_placement": placement,
            "overlay_placement_intent": NSNull(),
        ]
    }
}

@MainActor
private final class AgentSessionRouteGate {
    private(set) var openCount = 0
    private var continuation: CheckedContinuation<AgentSessionOpenOutcome, Never>?

    func open(_ route: AgentSessionOpenRoute) async -> AgentSessionOpenOutcome {
        _ = route
        openCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(with outcome: AgentSessionOpenOutcome) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: outcome)
    }
}

private actor OverlayPlacementRetrySleeperProbe {
    private(set) var delays: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waitCount: Int { delays.count }

    func sleep(_ duration: Duration) async {
        delays.append(duration)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor OverlayPlacementRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entered = false

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class OverlayPlacementJournalMemoryProbe {
    struct RemovalAttempt: Equatable {
        let expectedInteractionID: UUID
        let currentInteractionID: UUID?
    }

    var entry: OverlayPlacementJournalEntry?
    private(set) var savedEntries: [OverlayPlacementJournalEntry] = []
    private(set) var removedEntries: [OverlayPlacementJournalEntry] = []
    private(set) var removalAttempts: [RemovalAttempt] = []

    init(entry: OverlayPlacementJournalEntry? = nil) {
        self.entry = entry
    }

    var store: OverlayPlacementJournalStore {
        OverlayPlacementJournalStore(
            load: { self.entry },
            save: { entry in
                self.savedEntries.append(entry)
                self.entry = entry
            },
            removeIfMatching: { expected in
                self.removalAttempts.append(RemovalAttempt(
                    expectedInteractionID: expected.interactionID,
                    currentInteractionID: self.entry?.interactionID
                ))
                guard self.entry == expected else { return }
                self.removedEntries.append(expected)
                self.entry = nil
            }
        )
    }
}
