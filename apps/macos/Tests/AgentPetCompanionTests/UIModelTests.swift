import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct UIModelTests {
    @Test
    func packagedResourceBundleResolvesFromContentsResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "apc-resource-bundle-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = root.appendingPathComponent(
            APCResourceBundle.bundleName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)

        #expect(APCResourceBundle.packagedBundleURL(in: root) == expected)
        #expect(APCResourceBundle.packagedBundleURL(in: root.appendingPathComponent("missing")) == nil)
    }

    @Test
    func allV1CopyKeysExistInEnglishAndChinese() throws {
        for key in APCLocalization.requiredV1Keys {
            let english = try #require(APCLocalization.localizedValue(for: key, locale: "en"))
            let chinese = try #require(APCLocalization.localizedValue(for: key, locale: "zh-Hans"))
            #expect(!english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(english != key.rawValue)
            #expect(chinese != key.rawValue)
        }
    }

    @Test
    func stringCatalogMatchesPackagedRuntimeTranslations() throws {
        for key in APCLocalization.requiredV1Keys {
            for locale in ["en", "zh-Hans"] {
                let catalog = try #require(APCLocalization.catalogValue(for: key, locale: locale))
                let runtime = try #require(APCLocalization.localizedValue(for: key, locale: locale))
                #expect(catalog == runtime)
            }
        }
    }

    @Test
    func v1InterfaceUsesTheCompleteChineseSurfaceInsteadOfMixingLocales() {
        #expect(APCLocalization.interfaceLocaleIdentifier == "zh-Hans")
        #expect(APCLocalization.text(.navigationBehavior) == "启用与行为")
        #expect(APCLocalization.text(.studioTabLibrary) == "宠物库")
    }

    @Test
    func eventAndSourceControlsHaveDistinctLabels() {
        let sourceLabels = AgentSource.allCases.map(UIControlSemantics.sourceLabel)
        let eventLabels = AgentEventKind.allCases.map(UIControlSemantics.eventLabel)

        #expect(Set(sourceLabels).count == AgentSource.allCases.count)
        #expect(Set(eventLabels).count == AgentEventKind.allCases.count)
        for (source, label) in zip(AgentSource.allCases, sourceLabels) {
            #expect(label.contains(source.title))
        }
        for (event, label) in zip(AgentEventKind.allCases, eventLabels) {
            #expect(label.contains(event.title))
        }
        #expect(UIControlSemantics.toggleValue(isOn: true) != UIControlSemantics.toggleValue(isOn: false))
    }

    @Test
    func connectionGridIsTopAligned() throws {
        let overview = try #require(ConnectionGridLayout.overviewColumns.first)
        let cards = try #require(ConnectionGridLayout.cardColumns.first)
        #expect(overview.alignment == .top)
        #expect(cards.alignment == .top)
    }

    @Test
    func studioAdaptiveColumnsDependOnContainerWidthNotTextContent() {
        #expect(AdaptiveTwoColumnLayout.usesColumns(
            availableWidth: 760,
            minimumColumnWidth: 300,
            spacing: 18
        ))
        #expect(!AdaptiveTwoColumnLayout.usesColumns(
            availableWidth: 600,
            minimumColumnWidth: 300,
            spacing: 18
        ))
    }

    @Test
    func libraryUsesValidationSummary() {
        let pet = makePet(id: "pet_warning", active: true)
        let warning = PetAssetWarning(
            petId: pet.id,
            code: "pet_assets_invalid",
            fingerprint: "sha256:test",
            message: "idle frame is corrupt"
        )
        let invalid = PetLibraryPresentation(pet: pet, assetWarning: warning)
        let unverified = PetLibraryPresentation(pet: pet, assetWarning: nil)

        #expect(invalid.validationStatus == .invalid)
        #expect(invalid.validationDetail.contains("idle frame is corrupt"))
        #expect(unverified.validationStatus == .notFullyReported)
        #expect(unverified.validationTitle == "规格未完整报告")
        #expect(unverified.validationTitle.count < unverified.validationDetail.count)
        #expect(!unverified.validationDetail.contains("资源完整"))
        #expect(unverified.stateSpecification == nil)
        #expect(unverified.fpsSpecification == nil)

        var verifiedPet = pet
        verifiedPet.origin = .verifiedSkillSource
        verifiedPet.generator = "codex-app-server-skill"
        verifiedPet.provenance = "skill-full-source"
        let verified = PetLibraryPresentation(pet: verifiedPet, assetWarning: nil)
        #expect(verified.validationStatus == .verified)
        #expect(verified.validationTitle == "资源校验通过")
        #expect(verified.validationDetail.contains("PetCore 已验证"))
        #expect(verified.stateSpecification == "7 个固定状态 · 每状态至少 2 帧")
        #expect(verified.fpsSpecification == "标准 12 FPS · 流畅 20 FPS")
    }

    @Test
    func daemonAssetWarningsDecodeAndIndexByPetID() throws {
        let data = Data(#"[{"pet_id":"pet_a","code":"pet_assets_invalid","fingerprint":"sha256:a","message":"broken frame"}]"#.utf8)
        let warnings = try JSONDecoder().decode([PetAssetWarning].self, from: data)
        let index = PetAssetWarningIndex(warnings)

        #expect(index["pet_a"]?.message == "broken frame")
        #expect(index["pet_missing"] == nil)
    }

    @Test
    func importAcceptsOnlyPetpack() {
        #expect(PetpackImportPolicy.contentType.identifier == "dev.agentpet.petpack")
        #expect(PetpackImportPolicy.acceptsFileName("Cloud.petpack"))
        #expect(PetpackImportPolicy.acceptsFileName("Cloud.PETPACK"))
        #expect(!PetpackImportPolicy.acceptsFileName("Cloud.petdex"))
        #expect(!PetpackImportPolicy.acceptsFileName("Cloud.zip"))
        #expect(!PetpackImportPolicy.acceptsFileName("petpack"))
    }

    @Test
    func nonActivePetDoesNotShowGlobalEvent() {
        let event = AgentEvent(
            id: "evt_global",
            source: .codex,
            eventType: .tool,
            title: "执行工具",
            detail: nil,
            createdAt: "2026-07-10T00:00:00Z"
        )
        let inactive = PetLibraryPresentation(
            pet: makePet(id: "pet_inactive", active: false),
            assetWarning: nil
        )
        let active = PetLibraryPresentation(
            pet: makePet(id: "pet_active", active: true),
            assetWarning: nil
        )

        #expect(inactive.currentStateTitle(activeEvent: event) == nil)
        #expect(active.currentStateTitle(activeEvent: event) == event.eventType.title)
    }

    @Test
    func activeSessionBubbleKeepsLatestConversationMessageAndStatus() throws {
        let data = Data(
            #"{"state":"tool","official_status":"running","source":"codex","session_id":"session-1","session_active":true,"source_session_sequence":2,"priority":300,"lease_seconds":null,"expires_at":null,"event":{"id":"tool-2","source":"codex","session_id":"session-1","event_type":"tool","title":"执行工具","detail":null,"payload_json":{"schema_version":"apc.agent-event.v1","external_event_id":"tool-2","source_event":"PreToolUse","tool_name":"shell","outcome":"started","diagnostic":false,"turn_id":"turn-1","session_active":true,"message_role":null,"message_content":null,"activity_kind":"thinking","activity_content":"正在验证活动摘要同步","interaction_kind":null,"project_label":"agent-pet-companion"},"created_at":"2026-07-13T00:00:02Z"},"latest_message":{"id":"prompt-1","source":"codex","session_id":"session-1","event_type":"start","title":"开始处理","detail":null,"payload_json":{"schema_version":"apc.agent-event.v1","external_event_id":"prompt-1","source_event":"UserPromptSubmit","tool_name":null,"outcome":"started","diagnostic":false,"turn_id":"turn-1","session_active":true,"message_role":"user","message_content":"保持会话消息持续显示","interaction_kind":null,"project_label":"agent-pet-companion"},"created_at":"2026-07-13T00:00:01Z"},"session_activity":{"kind":"thinking","content":"正在验证活动摘要同步"}}"#.utf8
        )
        let state = try JSONDecoder().decode(ActiveAgentState.self, from: data)
        let content = OverlayBubbleContent(state: state)
        let session = try #require(content.sessions.first)

        #expect(session.messageText == "正在验证活动摘要同步")
        #expect(session.statusText == APCLocalization.text(.overlayStatusTool))
        #expect(content.agentName == "Codex")
        #expect(session.sessionTitle == "agent-pet-companion")
        #expect(session.sessionID == "session-1")
        #expect(
            AgentSessionDeepLink.url(source: .codex, sessionID: session.sessionID)?.absoluteString
                == "codex://threads/session-1"
        )
    }

    @Test
    func bubbleOpenAndCloseHitRegionsNeverOverlap() {
        let content = OverlayBubbleContent.idle
        let size = OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 1512, height: 934),
            content: content
        )
        let bubble = CGRect(origin: .zero, size: size)
        let close = OverlayGeometry.bubbleCloseHitRect(in: bubble)
        let sessions = OverlayGeometry.bubbleSessionRects(in: bubble, content: content)

        #expect(sessions.count == 1)
        #expect(!close.intersects(sessions[0]))
    }

    @MainActor
    @Test
    func expandingBubbleClearsGlobalAndSessionDismissals() {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        store.overlayBubbleDismissed = true
        store.overlayDismissedBubbleEventIDs = ["codex-session-event", "pi-session-event"]

        store.toggleOverlayBubble()

        #expect(!store.overlayBubbleDismissed)
        #expect(store.overlayDismissedBubbleEventIDs.isEmpty)
    }

    @Test
    func agentSessionRouterPrefersWarpPaneAndNeverBlindlyDeepLinksCodexCLI() throws {
        let warpURL = "warp://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4"
        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-1",
                navigation: AgentSessionNavigation(
                    sessionOpen: true,
                    surface: "cli_terminal",
                    terminalApp: "warp",
                    openURL: warpURL
                )
            ) == .url(try #require(URL(string: warpURL)))
        )

        let unknownSurface = try #require(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-1",
                navigation: AgentSessionNavigation(sessionOpen: true)
            )
        )
        guard case .application = unknownSurface else {
            Issue.record("unknown Codex surface must activate ChatGPT instead of using a thread deep link")
            return
        }

        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-1",
                navigation: AgentSessionNavigation(sessionOpen: false)
            ) == nil
        )
    }

    @Test
    func semanticTokensResolveInEveryAppearanceMode() throws {
        let appearances: [NSAppearance.Name] = [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua
        ]
        for token in APCSemanticColorToken.allCases {
            for appearance in appearances {
                let color = try #require(APCDesign.resolvedColor(token, appearance: appearance))
                #expect(color.alphaComponent > 0)
            }
        }
    }

    private func makePet(id: String, active: Bool) -> PetSummary {
        PetSummary(
            id: id,
            name: id,
            style: "半写实",
            quality: .high,
            renderSize: RenderSize(width: 384, height: 416),
            petpackPath: "/tmp/\(id).petpack",
            coverPath: "/tmp/\(id).webp",
            active: active,
            createdAt: "2026-07-10T00:00:00Z"
        )
    }
}
