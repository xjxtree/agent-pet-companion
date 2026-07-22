import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct AppStoreOverlaySnapshotTests {
    @MainActor
    @Test
    func idleBubbleAvailabilityKeepsContextMenuToggleUseful() throws {
        let store = makeStore()

        try store.applyStateSnapshot([
            "revision": "idle-overlay-1",
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

        #expect(store.overlayAvailableBubbleContents == [.idle])
        #expect(store.hasAvailableOverlayBubbleContent)

        store.overlayBubbleDismissed = true
        #expect(store.overlayBubbleContents.isEmpty)
        #expect(store.hasAvailableOverlayBubbleContent)

        try store.applyStateSnapshot([
            "revision": "idle-overlay-hidden-2",
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
    private func makeStore() -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { _ in }
        )
    }

    private func makeState(
        source: AgentSource,
        session: String,
        event: AgentEventKind,
        activatedSecond: Int
    ) -> ActiveAgentState {
        let summary: AgentOverlaySummaryKind = switch event {
        case .start: .running
        case .tool: .tool
        case .waiting: .needsInput
        case .review: .review
        case .done: .done
        case .failed: .failed
        }
        let timestamp = String(format: "2026-07-22T00:00:%02dZ", activatedSecond)
        return ActiveAgentState(
            state: event.rawValue,
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

    private func jsonArray<T: Encodable>(_ value: T) throws -> [Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [Any])
    }
}
