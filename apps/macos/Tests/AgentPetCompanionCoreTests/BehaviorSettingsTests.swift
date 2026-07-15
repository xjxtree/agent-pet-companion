import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct BehaviorSettingsTests {
    @Test
    func patchContainsOnlyChangedScalarAndMapEntries() throws {
        let previous = BehaviorSettings()
        var next = previous
        next.autoHide = true
        next.sessionMessageTimeoutMinutes = 30
        next.sources[.codex] = false
        next.events[.tool] = false

        let patch = BehaviorSettingsPatch(from: previous, to: next)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(!patch.isEmpty)
        #expect(object["auto_hide"] as? Bool == true)
        #expect(object["session_message_timeout_minutes"] as? Int == 30)
        let sources = try #require(object["sources"] as? [String: Any])
        let events = try #require(object["events"] as? [String: Any])
        #expect(sources.count == 1)
        #expect(sources["codex"] as? Bool == false)
        #expect(events.count == 1)
        #expect(events["tool"] as? Bool == false)
        #expect(object["enabled"] == nil)
        #expect(object["fps_profile"] == nil)
    }

    @Test
    func unchangedSettingsProduceNoMutation() {
        let behavior = BehaviorSettings()
        #expect(BehaviorSettingsPatch(from: behavior, to: behavior).isEmpty)
    }

    @Test
    func autoHideControlsOnlyIdleBubbleNotPetVisibility() {
        var behavior = BehaviorSettings()
        behavior.enabled = true
        behavior.statusBubble = true
        behavior.autoHide = true

        #expect(!behavior.showsStatusBubble(hasActiveEvent: false, dismissed: false))
        #expect(behavior.showsStatusBubble(hasActiveEvent: true, dismissed: false))
        #expect(behavior.enabled)

        behavior.autoHide = false
        #expect(behavior.showsStatusBubble(hasActiveEvent: false, dismissed: false))
        #expect(!behavior.showsStatusBubble(hasActiveEvent: true, dismissed: true))
    }

    @Test
    func canonicalActiveStateAndVisibilityDecodeFromSnapshotShape() throws {
        let data = Data(
            #"{"state":"tool","source":"codex","session_id":"s1","source_session_sequence":7,"priority":300,"lease_seconds":30,"expires_at":"2026-07-10T00:00:30Z","event":{"id":"evt1","source":"codex","event_type":"tool","title":"执行工具","detail":null,"created_at":"2026-07-10T00:00:00Z"}}"#.utf8
        )
        let state = try JSONDecoder().decode(ActiveAgentState.self, from: data)
        let visibility = try JSONDecoder().decode(
            OverlayVisibility.self,
            from: Data(#"{"pet_visible":true,"status_bubble_visible":false}"#.utf8)
        )

        #expect(state.event.id == "evt1")
        #expect(state.sourceSessionSequence == 7)
        #expect(state.leaseSeconds == 30)
        #expect(visibility.petVisible)
        #expect(!visibility.statusBubbleVisible)
    }
}
