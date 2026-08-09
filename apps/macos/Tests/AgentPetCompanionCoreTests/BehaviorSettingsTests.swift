import Foundation
import Testing
@testable import AgentPetCompanionCore

@Suite
struct BehaviorSettingsTests {
    @Test
    func everySupportedAgentSourceIsEnabledByDefaultAndWhenLegacyDataOmitsIt() throws {
        let defaults = BehaviorSettings()
        #expect(defaults.sources.count == AgentSource.allCases.count)
        #expect(AgentSource.allCases.allSatisfy {
            defaults.sources[$0] == true
        })

        let legacy = try JSONDecoder().decode(
            BehaviorSettings.self,
            from: Data(#"{"sources":{"codex":false}}"#.utf8)
        )
        #expect(legacy.sources[.codex] == false)
        #expect(legacy.sources[.claudeCode] == true)
        #expect(legacy.sources[.pi] == true)
        #expect(legacy.sources[.opencode] == true)
    }

    @Test
    func patchContainsOnlyChangedScalarAndMapEntries() throws {
        let previous = BehaviorSettings()
        var next = previous
        next.autoHide = true
        next.interfaceLanguage = .simplifiedChinese
        next.appearanceTheme = .dark
        next.sessionMessageTimeoutMinutes = 30
        next.groupSessionsByAgent = false
        next.sessionGroupDisplay = .expanded
        next.sources[.codex] = false
        next.events[.tool] = false

        let patch = BehaviorSettingsPatch(from: previous, to: next)
        let data = try JSONEncoder().encode(patch)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(!patch.isEmpty)
        #expect(object["auto_hide"] as? Bool == true)
        #expect(object["interface_language"] as? String == "simplified_chinese")
        #expect(object["appearance_theme"] as? String == "dark")
        #expect(object["session_message_timeout_minutes"] as? Int == 30)
        #expect(object["group_sessions_by_agent"] as? Bool == false)
        #expect(object["session_group_display"] as? String == "expanded")
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
    func bubbleTransparencyIsNotPartOfTheBehaviorContract() throws {
        let decoded = try JSONDecoder().decode(
            BehaviorSettings.self,
            from: Data(#"{"bubble_transparency":0.55}"#.utf8)
        )
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(decoded.interfaceLanguage == .system)
        #expect(decoded.appearanceTheme == .system)
        #expect(decoded.groupSessionsByAgent)
        #expect(decoded.sessionGroupDisplay == .stacked)
        #expect(object["bubble_transparency"] == nil)
    }

    @Test
    func transparentAreaPassthroughIsAlwaysEnabledAndCannotEnterAPatch() throws {
        let decoded = try JSONDecoder().decode(
            BehaviorSettings.self,
            from: Data(#"{"mouse_passthrough":false}"#.utf8)
        )
        #expect(decoded.mousePassthrough)

        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["mouse_passthrough"] as? Bool == true)

        let legacyPatch = try JSONDecoder().decode(
            BehaviorSettingsPatch.self,
            from: Data(#"{"mouse_passthrough":false}"#.utf8)
        )
        #expect(legacyPatch.isEmpty)
        let patchObject = try #require(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(legacyPatch)
            ) as? [String: Any]
        )
        #expect(patchObject["mouse_passthrough"] == nil)
    }

    @Test
    func languageAppearanceAndSessionGroupingRoundTrip() throws {
        let behavior = BehaviorSettings(
            interfaceLanguage: .english,
            appearanceTheme: .light,
            groupSessionsByAgent: false,
            sessionGroupDisplay: .expanded
        )
        let data = try JSONEncoder().encode(behavior)
        let decoded = try JSONDecoder().decode(BehaviorSettings.self, from: data)

        #expect(decoded.interfaceLanguage == .english)
        #expect(decoded.appearanceTheme == .light)
        #expect(!decoded.groupSessionsByAgent)
        #expect(decoded.sessionGroupDisplay == .expanded)
        #expect(SessionGroupDisplay.allCases.map(\.title) == ["堆叠", "展开"])
    }

    @Test
    func sessionGroupingPatchDecodesAndEncodesItsJSONKey() throws {
        let data = Data(
            #"{"group_sessions_by_agent":false,"session_group_display":"expanded"}"#.utf8
        )
        let patch = try JSONDecoder().decode(BehaviorSettingsPatch.self, from: data)

        #expect(patch.groupSessionsByAgent == false)
        #expect(patch.sessionGroupDisplay == .expanded)
        #expect(!patch.isEmpty)

        let encoded = try JSONEncoder().encode(patch)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object.count == 2)
        #expect(object["group_sessions_by_agent"] as? Bool == false)
        #expect(object["session_group_display"] as? String == "expanded")
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
