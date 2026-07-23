import AppKit
import Combine
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

    @MainActor
    @Test
    func approvedTransparentBrandMarkIsPackagedWithAlpha() throws {
        let resourceURL = APCResourceBundle.resourceURL(APCBrandAssets.markResourceName)
        let data = try Data(contentsOf: resourceURL)
        let bitmap = try #require(NSBitmapImageRep(data: data))

        #expect(bitmap.hasAlpha)
        #expect(APCBrandAssets.markImage.isValid)
        #expect(!APCBrandAssets.markImage.isTemplate)
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
    func v1InterfaceResolvesSupportedLocalesWithoutDependingOnTheHostLanguage() {
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: ["zh_CN", "en-US"]
        ) == "zh-Hans")
        #expect(APCLocalization.resolvedInterfaceLocaleIdentifier(
            preferredLanguages: ["fr-FR", "en-GB"]
        ) == "en")
        #expect(APCLocalization.text(.navigationLibrary, locale: "zh-Hans") == "宠物库")
        #expect(APCLocalization.text(.navigationLibrary, locale: "en") == "Pet Library")
        #expect(APCLocalization.text(.navigationDiagnostics, locale: "zh-Hans") == "服务与诊断")
        #expect(APCLocalization.text(.navigationDiagnostics, locale: "en") == "Service & Diagnostics")
    }

    @Test
    func sidebarNavigationUsesTheProductOrder() {
        #expect(
            NavigationSection.allCases
                == [.library, .maker, .configuration, .connections, .diagnostics]
        )
        #expect(
            NavigationSection.allCases.map(\.title)
                == ["宠物库", "AI宠物制作", "宠物配置", "Agent 连接", "服务与诊断"]
        )
    }

    @Test
    func runningServiceDiagnosticsUseTypedRowsInTheProductOrder() throws {
        var runtime = PetCoreRuntimeInfo.initial(manifest: nil)
        runtime.phase = .running
        runtime.version = "0.1.0"
        runtime.rpcProtocol = "v2"
        runtime.databaseSchemaRange = "0–6"

        let presentation = ServiceDiagnosticsPresentation(
            runtimeInfo: runtime,
            serviceStatusText: "本地服务运行中",
            recentEventSummary: "Codex · 执行工具",
            desktopPetEnabled: true,
            desktopPetVisible: true,
            activePetName: "Bytebud 字节芽",
            framesPerSecond: 10,
            localeIdentifier: "zh-Hans"
        )

        #expect(presentation.rows.map(\.id) == ServiceDiagnosticKind.allCases)
        #expect(try #require(presentation.row(.petCore)).status == "正常")
        #expect(try #require(presentation.row(.localRPC)).detail == "v2 · Schema 0–6")
        #expect(try #require(presentation.row(.eventChannel)).status == "在线")
        #expect(
            try #require(presentation.row(.desktopPet)).detail
                == "10 FPS · Bytebud 字节芽"
        )
        #expect(ServiceDiagnosticsPresentation.toolbar(
            runtimeInfo: runtime,
            localeIdentifier: "zh-Hans"
        ).tone == .healthy)
    }

    @Test
    func failedServiceDiagnosticsKeepFailureAndDisabledOverlayDistinct() throws {
        var runtime = PetCoreRuntimeInfo.initial(manifest: nil)
        runtime.markFailed("runtime identity mismatch")

        let presentation = ServiceDiagnosticsPresentation(
            runtimeInfo: runtime,
            serviceStatusText: "PetCore 启动失败",
            recentEventSummary: nil,
            desktopPetEnabled: false,
            desktopPetVisible: false,
            activePetName: nil,
            framesPerSecond: 20,
            localeIdentifier: "zh-Hans"
        )

        let petCore = try #require(presentation.row(.petCore))
        #expect(petCore.tone == .failure)
        #expect(petCore.detail == "PetCore 当前不可用。")
        #expect(try #require(presentation.row(.localRPC)).status == "异常")
        #expect(try #require(presentation.row(.eventChannel)).status == "异常")
        #expect(try #require(presentation.row(.desktopPet)).tone == .inactive)
        #expect(ServiceDiagnosticsPresentation.toolbar(
            runtimeInfo: runtime,
            localeIdentifier: "zh-Hans"
        ).title == "服务异常")
    }

    @MainActor
    @Test
    func controlCenterOpensOnThePetLibrary() {
        #expect(makeStore().selection == .library)
    }

    @Test
    func bundledPetsExposeOnlyReadOnlyLibraryActions() {
        var pet = makePet(id: "pet_xingwutuanzi", active: true)
        pet.origin = .verifiedSkillSource
        pet.generator = "agent-pet-companion.release-inventory"
        pet.provenance = "apc.bundled-pets.v1"
        let bundled = PetLibraryCapabilities(pet: pet)
        #expect(bundled.isBundled)
        #expect(!bundled.canModify)
        #expect(!bundled.canDelete)

        pet.origin = .externalImport
        let imported = PetLibraryCapabilities(pet: pet)
        #expect(!imported.isBundled)
        #expect(imported.canModify)
        #expect(imported.canDelete)

        pet.id = "pet_generated"
        pet.origin = .verifiedSkillSource
        let generated = PetLibraryCapabilities(pet: pet)
        #expect(generated.canModify)
        #expect(generated.canDelete)
    }

    @MainActor
    @Test
    func appStoreRejectsBundledPetEditsBeforeCallingPetCore() {
        let store = makeStore()
        var pet = makePet(id: "pet_xingwutuanzi", active: true)
        pet.origin = .verifiedSkillSource
        pet.generator = "agent-pet-companion.release-inventory"
        pet.provenance = "apc.bundled-pets.v1"

        store.startPetEdit(pet, instruction: "换一个动作")

        #expect(store.generationSession.state == .idle)
        #expect(store.generationSession.resultPetID == nil)
        #expect(store.statusText.contains("App 内置宠物不可原地修改"))
    }

    @Test
    func editHistoryCopyExplainsSelectableOwnedBaselinesAndSafeFallbacks() {
        let checking = PetEditHistoryPresentation(
            state: .checking,
            localeIdentifier: "zh-Hans"
        )
        #expect(checking.detail.contains("只读修改基线"))

        let available = PetEditHistoryPresentation(
            state: .available(operation: .create, status: "completed"),
            localeIdentifier: "zh-Hans"
        )
        #expect(available.title == "已找到最近一次 App 内记录")
        #expect(available.detail.contains("只读基线"))
        #expect(available.detail.contains("新 revision"))

        let unavailable = PetEditHistoryPresentation(
            state: .unavailable,
            localeIdentifier: "zh-Hans"
        )
        #expect(unavailable.title == "没有 App 内制作记录")
        #expect(unavailable.detail.contains("外部导入"))
        #expect(unavailable.detail.contains("安全回退"))
        #expect(unavailable.detail.contains("当前已校验 revision"))

        let lookupFailed = PetEditHistoryPresentation(
            state: .lookupFailed,
            localeIdentifier: "zh-Hans"
        )
        #expect(lookupFailed.detail.contains("当前已校验 revision"))
        #expect(lookupFailed.detail.contains("绝不会借用当前封面"))
    }

    @Test
    func modificationWorkspaceSurvivesTerminalSessionStates() {
        for state in [
            GenerationSessionState.starting,
            .running,
            .waitingForInput,
            .cancelling,
            .succeeded,
            .failed,
            .cancelled,
        ] {
            let session = GenerationSession(
                state: state,
                operation: .modify,
                resultPetID: "pet_edit_target"
            )
            #expect(PetStudioPresentation.showsModificationWorkspace(for: session))
        }

        #expect(!PetStudioPresentation.showsModificationWorkspace(for: GenerationSession()))
        #expect(!PetStudioPresentation.showsModificationWorkspace(for: GenerationSession(
            state: .succeeded,
            operation: .create,
            resultPetID: "pet_created"
        )))
    }

    @MainActor
    @Test
    func startingANewDraftExplicitlyLeavesATerminalModificationWorkspace() {
        let store = makeStore()
        _ = store.reduceGeneration(.restore(GenerationSessionRestore(
            state: .succeeded,
            jobID: "job_edit_complete",
            submittedForm: nil,
            messages: [],
            progress: 1,
            messageRevision: "7",
            operation: .modify,
            resultPetID: "pet_edit_target"
        )))

        store.showNewPetDraft()

        #expect(store.generationSession.state == .idle)
        #expect(store.generationSession.operation == .create)
        #expect(store.generationSession.resultPetID == nil)
        #expect(store.selection == .maker)
    }

    @MainActor
    @Test
    func clearingStudioFormRestoresTheCompleteDefaultBrief() {
        let store = makeStore()

        #expect(!store.canClearStudioForm)
        store.selectGenerationStyle(.pixel)
        store.selectGenerationQuality(.ultra)
        store.selectGenerationNativeFPS(20)
        store.selectGenerationStateDuration(1_000, for: "idle")
        #expect(store.canClearStudioForm)

        store.clearStudioForm()

        #expect(store.selectedStyle == AIPetMakerDefaults.style)
        #expect(store.selectedQuality == AIPetMakerDefaults.quality)
        #expect(store.selectedNativeFPS == PetAnimationContract.defaultNativeFPS)
        #expect(store.generationStateDurationsMS == PetAnimationContract.defaultStateDurationsMS)
        #expect(!store.canClearStudioForm)
    }

    @MainActor
    @Test
    func viewingHistoryCannotReplaceAnActiveGenerationSession() {
        let store = makeStore()
        let form = GenerationForm(
            description: "active edit",
            style: StylePreset.semiRealistic.rawValue,
            quality: .high,
            referenceImages: []
        )
        _ = store.reduceGeneration(.editRequested(
            form: form,
            initialMessage: GenerationMessage(
                role: "user",
                content: "keep this session active",
                progress: 0.01,
                createdAt: ""
            ),
            petID: "pet_active"
        ))
        let activeSession = store.generationSession

        store.openGenerationHistory(for: makePet(id: "pet_other", active: false))

        #expect(store.generationSession == activeSession)
        #expect(store.statusText.contains("完成或取消当前 AI 制作任务"))
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
            #expect(label.contains(APCLocalizedPresentation.eventTitle(event)))
        }
        #expect(UIControlSemantics.toggleValue(isOn: true) != UIControlSemantics.toggleValue(isOn: false))
    }

    @MainActor
    @Test
    func connectionOperationsAreAgentScopedWithoutAProjectDimension() {
        let selectedAgent = AppStore.connectionOperationParameters(source: .pi)
        #expect(selectedAgent == ["source": AgentSource.pi.rawValue])

        let allAgents = AppStore.connectionOperationParameters()
        #expect(allAgents.isEmpty)
    }

    @MainActor
    @Test
    func authoritativeLightConnectionSnapshotDoesNotKeepStaleRuntimeVerification() {
        let store = makeStore()
        store.connections = [
            AgentConnectionStatus(
                source: .pi,
                items: [],
                installPaths: ["/tmp/agent-pet-companion.ts"],
                connectorInstalled: true,
                checkMode: .runtime,
                checkedAt: "2026-07-17T09:00:00Z",
                verification: AgentVerification(
                    status: .verified,
                    title: "已通过宿主验证",
                    detail: "旧的完整检查结果",
                    lastVerifiedAt: "2026-07-17T09:00:00Z"
                )
            )
        ]
        let expiredLightSnapshot = AgentConnectionStatus(
            source: .pi,
            items: [],
            installPaths: ["/tmp/agent-pet-companion.ts"],
            connectorInstalled: true,
            checkMode: .light,
            checkedAt: "2026-07-17T09:06:00Z",
            verification: AgentVerification(
                status: .unverified,
                title: "宿主验证已过期",
                detail: "请重新执行完整检查。"
            )
        )

        store.applyAuthoritativeConnectionSnapshot([expiredLightSnapshot])

        let status = store.connections.first
        #expect(status?.checkMode == .light)
        #expect(status?.checkedAt == "2026-07-17T09:06:00Z")
        #expect(status?.verification.status == .unverified)
        #expect(status?.verification.lastVerifiedAt == nil)
    }

    @MainActor
    @Test
    func identicalConnectionSnapshotsDoNotRepublishTheWholeAppStore() {
        let store = makeStore()
        let snapshot = [
            AgentConnectionStatus(
                source: .opencode,
                items: [],
                installPaths: ["/tmp/agent-pet-companion.js"],
                connectorInstalled: true,
                checkMode: .light,
                checkedAt: "2026-07-20T00:00:00Z"
            )
        ]
        var publications = 0
        let observation = store.$connections.dropFirst().sink { _ in
            publications += 1
        }

        store.applyAuthoritativeConnectionSnapshot(snapshot)
        store.applyAuthoritativeConnectionSnapshot(snapshot)

        #expect(publications == 1)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    @Test
    func identicalGenerationRestoresDoNotRepublishTheWholeAppStore() {
        let store = makeStore()
        let restore = GenerationSessionRestore(
            state: .succeeded,
            jobID: "job-stable",
            submittedForm: nil,
            messages: [],
            progress: 1,
            messageRevision: "7",
            operation: .create,
            resultPetID: "pet-stable"
        )
        var publications = 0
        let observation = store.$generationSession.dropFirst().sink { _ in
            publications += 1
        }

        _ = store.reduceGeneration(.restore(restore))
        _ = store.reduceGeneration(.restore(restore))

        #expect(publications == 1)
        withExtendedLifetime(observation) {}
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
        var pet = makePet(id: "pet_warning", active: true)
        pet.nativeFPS = 20
        let warning = PetAssetWarning(
            petId: pet.id,
            code: "pet_assets_invalid",
            fingerprint: "sha256:test",
            message: "idle frame is corrupt"
        )
        let invalid = PetLibraryPresentation(
            pet: pet,
            assetWarning: warning,
            localeIdentifier: "zh-Hans"
        )
        let imported = PetLibraryPresentation(
            pet: pet,
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )

        #expect(invalid.validationStatus == .invalid)
        #expect(invalid.validationDetail.contains("idle frame is corrupt"))
        #expect(imported.validationStatus == .verified)
        #expect(imported.validationTitle == "资源校验通过")
        #expect(imported.validationDetail.contains("PetCore 已验证"))
        #expect(imported.stateSpecification == "7 个固定状态 · 帧数严格匹配原生帧率与动作时长")
        #expect(imported.fpsSpecification == "原生 20 FPS · 可播放 10 / 20 FPS")

        var verifiedPet = pet
        verifiedPet.origin = .verifiedSkillSource
        verifiedPet.generator = "codex-app-server-skill"
        verifiedPet.provenance = "skill-full-source"
        let verified = PetLibraryPresentation(
            pet: verifiedPet,
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        #expect(verified.validationStatus == .verified)
        #expect(verified.validationTitle == "资源校验通过")
        #expect(verified.validationDetail.contains("PetCore 已验证"))
        #expect(verified.stateSpecification == "7 个固定状态 · 帧数严格匹配原生帧率与动作时长")
        #expect(verified.fpsSpecification == "原生 20 FPS · 可播放 10 / 20 FPS")
    }

    @MainActor
    @Test
    func activationRefreshFailureDoesNotMisreportTheSuccessfulMutation() async {
        let store = makeStore()
        let pet = makePet(id: "pet_activation_refresh", active: false)
        var mutationCalls = 0
        var recoveryCalls = 0

        await store.finishPetActivation(
            pet,
            activate: { mutationCalls += 1 },
            refreshSnapshot: {
                throw NSError(
                    domain: "AgentPetCompanionTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "snapshot unavailable"]
                )
            },
            recoverSnapshot: { recoveryCalls += 1 }
        )

        #expect(mutationCalls == 1)
        #expect(recoveryCalls == 1)
        #expect(store.statusText == "已启用 pet_activation_refresh，但状态刷新失败：snapshot unavailable")
        #expect(!store.statusText.contains("启用失败"))
    }

    @MainActor
    @Test
    func activationMutationFailureRemainsAnActivationFailure() async {
        let store = makeStore()
        let pet = makePet(id: "pet_activation_mutation", active: false)
        var snapshotCalls = 0
        var recoveryCalls = 0

        await store.finishPetActivation(
            pet,
            activate: {
                throw NSError(
                    domain: "AgentPetCompanionTests",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "activation rejected"]
                )
            },
            refreshSnapshot: { snapshotCalls += 1 },
            recoverSnapshot: { recoveryCalls += 1 }
        )

        #expect(snapshotCalls == 0)
        #expect(recoveryCalls == 1)
        #expect(store.statusText == "启用失败：activation rejected")
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
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )
        let active = PetLibraryPresentation(
            pet: makePet(id: "pet_active", active: true),
            assetWarning: nil,
            localeIdentifier: "zh-Hans"
        )

        #expect(inactive.currentStateTitle(activeEvent: event) == nil)
        #expect(
            active.currentStateTitle(activeEvent: event)
                == APCLocalizedPresentation.eventTitle(event.eventType, locale: "zh-Hans")
        )
    }

    @Test
    func activeSessionBubbleUsesBoundedConversationDisplayContent() throws {
        let data = Data(
            #"{"state":"tool","official_status":"running","source":"codex","session_id":"ses-projected-session-1","session_active":true,"source_session_sequence":2,"priority":300,"lease_seconds":null,"expires_at":null,"event":{"id":"evt-projected-tool-2","source":"codex","session_id":"ses-projected-session-1","event_type":"tool","title":"执行工具","detail":null,"payload_json":{"schema_version":"apc.agent-event.v1","external_event_id":"tool-2","source_event":"PreToolUse","tool_name":"shell","outcome":"started","diagnostic":false,"turn_id":"turn-1","session_active":true,"message_role":null,"message_content":null,"activity_kind":"thinking","activity_content":"正在验证活动摘要同步","interaction_kind":null,"project_label":"agent-pet-companion"},"created_at":"2026-07-13T00:00:02Z"},"session_title":"保持会话消息持续显示","session_user_message":{"role":"user","content":"保持会话消息持续显示"},"session_message":{"role":"assistant","content":"已恢复气泡消息内容。"},"session_activity":{"kind":"thinking","content":"正在验证活动摘要同步"},"overlay_display":{"summary_kind":"thinking","navigation":{"capability":"exact_session","session_open":true,"surface":"chatgpt_app","terminal_app":null,"open_url":null,"routable_session_id":"019f5b0f-88ff-7413-8953-29de4ed0951c"}}}"#.utf8
        )
        let state = try JSONDecoder().decode(ActiveAgentState.self, from: data)
        let content = OverlayBubbleContent(state: state)
        let session = try #require(content.sessions.first)

        #expect(session.messageText == "已恢复气泡消息内容。")
        #expect(session.statusText == APCLocalizedPresentation.lifecycleTitle(.tool))
        #expect(content.agentName == "Codex")
        #expect(session.sessionTitle == "保持会话消息持续显示")
        #expect(session.sessionID == "ses-projected-session-1")
        #expect(session.navigationCapability == .exactSession)
        #expect(session.actionLabel == APCLocalizedPresentation.navigationActionTitle(
            .exactSession,
            source: .codex
        ))
        #expect(
            AgentSessionDeepLink.url(
                source: .codex,
                sessionID: session.navigation.routableSessionID
            )?.absoluteString == "codex://threads/019f5b0f-88ff-7413-8953-29de4ed0951c"
        )
    }

    @Test
    func overlaySessionIdentityIsStableWhileEventRevisionChanges() throws {
        func state(eventID: String) throws -> ActiveAgentState {
            let json = """
            {"state":"tool","official_status":"running","source":"codex","session_id":"stable-session","session_active":true,"source_session_sequence":2,"priority":300,"lease_seconds":null,"expires_at":null,"session_activated_at":"2026-07-17T00:00:00Z","event":{"id":"\(eventID)","source":"codex","session_id":"stable-session","event_type":"tool","title":"执行工具","detail":null,"payload_json":{"turn_id":"turn-1","session_active":true},"created_at":"2026-07-17T00:00:01Z"}}
            """
            return try JSONDecoder().decode(ActiveAgentState.self, from: Data(json.utf8))
        }

        let first = OverlaySessionContent(state: try state(eventID: "tool-1"))
        let second = OverlaySessionContent(state: try state(eventID: "tool-2"))

        #expect(first.id == second.id)
        #expect(first.id == "session-codex-stable-session")
        #expect(first.eventID == "tool-1")
        #expect(second.eventID == "tool-2")
    }

    @Test
    func unattributedSessionIdentityAndDismissalSurviveEventRevision() throws {
        func state(eventID: String) throws -> ActiveAgentState {
            let json = """
            {"state":"tool","official_status":"running","source":"codex","session_id":null,"session_active":true,"source_session_sequence":2,"priority":300,"lease_seconds":null,"expires_at":null,"session_activated_at":"2026-07-20T00:00:00Z","event":{"id":"\(eventID)","source":"codex","session_id":null,"event_type":"tool","title":"执行工具","detail":null,"payload_json":{"turn_id":"turn-1","session_active":true},"created_at":"2026-07-20T00:00:01Z"}}
            """
            return try JSONDecoder().decode(ActiveAgentState.self, from: Data(json.utf8))
        }

        let first = try state(eventID: "unattributed-tool-1")
        let second = try state(eventID: "unattributed-tool-2")
        let firstContent = OverlaySessionContent(state: first)
        let secondContent = OverlaySessionContent(state: second)

        #expect(firstContent.id == "session-codex-unattributed")
        #expect(secondContent.id == firstContent.id)
        #expect(secondContent.eventID != firstContent.eventID)
        let dismissedSessionIDs: Set<String> = [firstContent.id]
        #expect(dismissedSessionIDs.contains(secondContent.id))
    }

    @Test
    func persistentAnonymousAliasesSurviveReorderingWithoutBecomingDisplayData() throws {
        func state(
            alias: String,
            eventID: String,
            activatedAt: String
        ) throws -> ActiveAgentState {
            let json = """
            {"state":"tool","official_status":"running","source":"codex","session_id":null,"anonymous_session_alias":"\(alias)","session_active":true,"source_session_sequence":2,"priority":300,"lease_seconds":30,"expires_at":null,"session_activated_at":"\(activatedAt)","event":{"id":"\(eventID)","source":"codex","session_id":null,"event_type":"tool","title":"Executing tool","detail":null,"created_at":"\(activatedAt)"}}
            """
            return try JSONDecoder().decode(ActiveAgentState.self, from: Data(json.utf8))
        }

        let first = try state(
            alias: "anon-1",
            eventID: "anonymous-a",
            activatedAt: "2026-07-20T00:00:01Z"
        )
        let second = try state(
            alias: "anon-2",
            eventID: "anonymous-b",
            activatedAt: "2026-07-20T00:00:02Z"
        )

        let original = OverlayBubbleContent(source: .codex, states: [first, second])
        let reordered = OverlayBubbleContent(source: .codex, states: [second, first])
        let originalByID = Dictionary(
            uniqueKeysWithValues: original.sessions.map { ($0.id, $0.sessionTitle) }
        )
        let reorderedByID = Dictionary(
            uniqueKeysWithValues: reordered.sessions.map { ($0.id, $0.sessionTitle) }
        )

        #expect(originalByID == reorderedByID)
        #expect(originalByID["session-codex-anon-1"] == APCLocalization.format(
            .overlaySessionAliasTitleFormat,
            "Codex",
            "A"
        ))
        #expect(originalByID["session-codex-anon-2"] == APCLocalization.format(
            .overlaySessionAliasTitleFormat,
            "Codex",
            "B"
        ))
        #expect(!original.sessions.map(\.sessionTitle).joined().contains("anon-"))

        let resolved = OverlayPresentedAgentState.resolve(
            canonicalState: first,
            activeSessions: [first, second],
            dismissedSessionIDs: ["session-codex-anon-1"]
        )
        #expect(resolved?.anonymousSessionAlias == "anon-2")
    }

    @Test
    func malformedAnonymousAliasFailsClosedToTheGenericSessionLabel() throws {
        let state = try JSONDecoder().decode(
            ActiveAgentState.self,
            from: Data(
                #"{"state":"tool","source":"codex","session_id":null,"anonymous_session_alias":"../../project/private","source_session_sequence":1,"priority":300,"event":{"id":"malformed-alias","source":"codex","event_type":"tool","title":"Executing tool","created_at":"2026-07-20T00:00:00Z"}}"#.utf8
            )
        )
        let content = OverlaySessionContent(state: state)

        #expect(content.id == "session-codex-unattributed")
        #expect(content.sessionTitle == APCLocalization.format(
            .overlaySessionTitleFormat,
            "Codex"
        ))
        #expect(!content.sessionTitle.contains("project"))
    }

    @Test
    func appServerClockAndPrivateActivityCopyDoNotChangeOverlayPresentation() throws {
        func state(createdAt: String, expiresAt: String, activity: String) throws -> ActiveAgentState {
            let json = """
            {"state":"tool","official_status":"running","source":"codex","session_id":"stable-session","session_active":true,"source_session_sequence":2,"priority":300,"lease_seconds":600,"expires_at":"\(expiresAt)","session_activated_at":"2026-07-20T00:00:00Z","event":{"id":"app-server-stable-turn","source":"codex","session_id":"stable-session","event_type":"tool","title":"执行工具","detail":null,"payload_json":{"source_event":"app_server_activity","turn_id":"turn-1","session_active":true,"activity_kind":"tool","activity_content":"\(activity)"},"created_at":"\(createdAt)"},"session_activity":{"kind":"tool","content":"\(activity)"},"overlay_display":{"summary_kind":"tool","navigation":{"session_open":true,"surface":"chatgpt_app","terminal_app":null,"open_url":null}}}
            """
            return try JSONDecoder().decode(ActiveAgentState.self, from: Data(json.utf8))
        }

        let first = try state(
            createdAt: "2026-07-20T00:00:01Z",
            expiresAt: "2026-07-20T00:10:01Z",
            activity: "正在执行"
        )
        let renewed = try state(
            createdAt: "2026-07-20T00:00:05Z",
            expiresAt: "2026-07-20T00:10:05Z",
            activity: "正在执行"
        )
        let changed = try state(
            createdAt: "2026-07-20T00:00:05Z",
            expiresAt: "2026-07-20T00:10:05Z",
            activity: "正在检查测试"
        )

        #expect(first.hasSamePresentation(as: renewed))
        #expect(first.hasSamePresentation(as: changed))
        #expect(first.event.hasSamePresentation(as: renewed.event))
    }

    @Test
    func equivalentOpenCodeIdleEdgesDoNotRepublishTheOverlay() throws {
        func state(
            eventID: String,
            sequence: Int,
            sourceEvent: String,
            sessionOpen: Bool,
            includeThinkingActivity: Bool
        ) throws -> ActiveAgentState {
            let activityPayload = includeThinkingActivity
                ? ",\"activity_kind\":\"thinking\""
                : ""
            let activityState = includeThinkingActivity
                ? ",\"session_activity\":{\"kind\":\"thinking\",\"content\":null}"
                : ""
            let json = """
            {"state":"done","official_status":"ready","source":"opencode","session_id":"idle-session","session_active":false,"source_session_sequence":\(sequence),"priority":400,"lease_seconds":5,"expires_at":"2026-07-20T00:00:10Z","session_activated_at":"2026-07-20T00:00:00Z","event":{"id":"\(eventID)","source":"opencode","session_id":"idle-session","event_type":"done","title":"任务完成","detail":null,"payload_json":{"source_event":"\(sourceEvent)","outcome":"idle","session_active":false,"session_open":\(sessionOpen)\(activityPayload)},"created_at":"2026-07-20T00:00:05Z"}\(activityState),"overlay_display":{"summary_kind":"done","navigation":{"session_open":\(sessionOpen),"surface":"unknown","terminal_app":"unknown","open_url":null}}}
            """
            return try JSONDecoder().decode(ActiveAgentState.self, from: Data(json.utf8))
        }

        let statusIdle = try state(
            eventID: "status-idle",
            sequence: 41,
            sourceEvent: "session.status",
            sessionOpen: true,
            includeThinkingActivity: true
        )
        let deprecatedIdle = try state(
            eventID: "deprecated-idle",
            sequence: 42,
            sourceEvent: "session.idle",
            sessionOpen: true,
            includeThinkingActivity: false
        )
        let deleted = try state(
            eventID: "deleted",
            sequence: 43,
            sourceEvent: "session.deleted",
            sessionOpen: false,
            includeThinkingActivity: false
        )

        #expect(statusIdle.hasSamePresentation(as: deprecatedIdle))
        #expect(!statusIdle.event.hasSamePresentation(as: deprecatedIdle.event))
        #expect(!deprecatedIdle.hasSamePresentation(as: deleted))
    }

    @Test
    func loopingPetStatesDoNotReloadForEveryHookEvent() throws {
        let firstTool = try animationState(
            source: .codex,
            eventID: "tool-1",
            sessionID: "session-a",
            eventType: .tool,
            turnID: "turn-a",
            sourceEvent: "PreToolUse",
            sessionActivatedAt: "2026-07-17T00:00:00Z"
        )
        let secondTool = try animationState(
            source: .codex,
            eventID: "tool-2",
            sessionID: "session-b",
            eventType: .tool,
            turnID: "turn-b",
            sourceEvent: "PreToolUse",
            sessionActivatedAt: "2026-07-17T00:00:01Z"
        )

        #expect(
            OverlayPetAnimationIdentity.stateEntryID(for: firstTool)
                == OverlayPetAnimationIdentity.stateEntryID(for: secondTool)
        )
        #expect(
            OverlayPetAnimationIdentity.stateEntryID(for: nil as ActiveAgentState?) == "idle"
        )
    }

    @Test
    func startAnimationUsesCanonicalUserActivationAcrossEveryAgent() throws {
        let scenarios: [(AgentSource, String, String, String?)] = [
            (.codex, "app_server_activity", "app_server_activity", "user"),
            (.claudeCode, "SessionStart", "UserPromptSubmit", "user"),
            (.pi, "agent_start", "input", "user"),
            (.opencode, "session.status", "message.user", "user")
        ]
        var firstEntryIDs = Set<String>()

        for (source, progressionEvent, activationEvent, activationRole) in scenarios {
            let sessionID = "session-\(source.rawValue)"
            let firstProgression = try animationState(
                source: source,
                eventID: "progress-1-\(source.rawValue)",
                sessionID: sessionID,
                eventType: .start,
                turnID: "turn-1",
                sourceEvent: progressionEvent,
                sessionActivatedAt: "2026-07-17T00:00:00Z"
            )
            let secondProgression = try animationState(
                source: source,
                eventID: "progress-2-\(source.rawValue)",
                sessionID: sessionID,
                eventType: .start,
                turnID: "turn-2",
                sourceEvent: progressionEvent,
                sessionActivatedAt: "2026-07-17T00:00:00Z"
            )
            let nextUserActivation = try animationState(
                source: source,
                eventID: "user-2-\(source.rawValue)",
                sessionID: sessionID,
                eventType: .start,
                turnID: "turn-3",
                sourceEvent: activationEvent,
                messageRole: activationRole,
                sessionActivatedAt: "2026-07-17T00:01:00Z"
            )

            let firstID = OverlayPetAnimationIdentity.stateEntryID(for: firstProgression)
            let secondID = OverlayPetAnimationIdentity.stateEntryID(for: secondProgression)
            let nextActivationID = OverlayPetAnimationIdentity.stateEntryID(
                for: nextUserActivation
            )
            #expect(firstID == secondID)
            #expect(firstID != nextActivationID)
            firstEntryIDs.insert(firstID)
        }

        #expect(firstEntryIDs.count == scenarios.count)
    }

    @Test
    func doneAnimationPlaysOncePerCanonicalActivationAcrossEveryAgent() throws {
        let scenarios: [(AgentSource, String, String)] = [
            (.codex, "app_server_activity", "app_server_activity"),
            (.claudeCode, "Stop", "SessionEnd"),
            (.pi, "turn_end", "agent_end"),
            (.opencode, "message.assistant", "session.idle")
        ]

        for (source, firstCompletionEvent, secondCompletionEvent) in scenarios {
            let sessionID = "session-\(source.rawValue)"
            let firstCompletion = try animationState(
                source: source,
                eventID: "done-1-\(source.rawValue)",
                sessionID: sessionID,
                eventType: .done,
                turnID: nil,
                sourceEvent: firstCompletionEvent,
                sessionActivatedAt: "2026-07-17T00:00:00Z"
            )
            let duplicateCompletion = try animationState(
                source: source,
                eventID: "done-2-\(source.rawValue)",
                sessionID: sessionID,
                eventType: .done,
                turnID: nil,
                sourceEvent: secondCompletionEvent,
                sessionActivatedAt: "2026-07-17T00:00:00Z"
            )
            let nextActivationCompletion = try animationState(
                source: source,
                eventID: "done-3-\(source.rawValue)",
                sessionID: sessionID,
                eventType: .done,
                turnID: nil,
                sourceEvent: secondCompletionEvent,
                sessionActivatedAt: "2026-07-17T00:01:00Z"
            )

            let firstID = OverlayPetAnimationIdentity.stateEntryID(for: firstCompletion)
            #expect(
                firstID == OverlayPetAnimationIdentity.stateEntryID(for: duplicateCompletion)
            )
            #expect(
                firstID != OverlayPetAnimationIdentity.stateEntryID(for: nextActivationCompletion)
            )
        }

        let legacyTurnCompletion = try animationState(
            source: .opencode,
            eventID: "legacy-done-1",
            sessionID: "legacy-session",
            eventType: .done,
            turnID: "legacy-turn",
            sourceEvent: "message.assistant",
            sessionActivatedAt: nil
        )
        let duplicateLegacyTurnCompletion = try animationState(
            source: .opencode,
            eventID: "legacy-done-2",
            sessionID: "legacy-session",
            eventType: .done,
            turnID: "legacy-turn",
            sourceEvent: "session.idle",
            sessionActivatedAt: nil
        )
        #expect(
            OverlayPetAnimationIdentity.stateEntryID(for: legacyTurnCompletion)
                == OverlayPetAnimationIdentity.stateEntryID(for: duplicateLegacyTurnCompletion)
        )

        let noActivation = try animationState(
            source: .claudeCode,
            eventID: "unscoped-done-1",
            sessionID: "unscoped-session",
            eventType: .done,
            turnID: nil,
            sourceEvent: "Stop",
            sessionActivatedAt: nil
        )
        let duplicateNoActivation = try animationState(
            source: .claudeCode,
            eventID: "unscoped-done-2",
            sessionID: "unscoped-session",
            eventType: .done,
            turnID: nil,
            sourceEvent: "SessionEnd",
            sessionActivatedAt: nil
        )
        #expect(
            OverlayPetAnimationIdentity.stateEntryID(for: noActivation)
                == OverlayPetAnimationIdentity.stateEntryID(for: duplicateNoActivation)
        )
    }

    @Test
    func bubbleRowHeightDoesNotChangeBetweenOneAndTwoDetailLines() {
        let short = OverlaySessionContent(
            id: "short",
            source: .codex,
            sessionID: "short",
            eventType: .tool,
            sessionTitle: "Short",
            messageText: "一行",
            statusText: "正在使用工具"
        )
        let long = OverlaySessionContent(
            id: "long",
            source: .codex,
            sessionID: "long",
            eventType: .tool,
            sessionTitle: "Long",
            messageText: "这是一段会自动换到第二行的较长活动描述，用来验证面板高度不会随着 hook 内容改变",
            statusText: "正在使用工具"
        )
        let shortContent = OverlayBubbleContent(
            id: "short-content",
            source: .codex,
            agentName: "Codex",
            sessions: [short]
        )
        let longContent = OverlayBubbleContent(
            id: "long-content",
            source: .codex,
            agentName: "Codex",
            sessions: [long]
        )

        #expect(
            OverlayGeometry.bubbleSessionRowHeights(
                bubbleWidth: OverlayGeometry.bubbleWidth,
                content: shortContent
            ) == OverlayGeometry.bubbleSessionRowHeights(
                bubbleWidth: OverlayGeometry.bubbleWidth,
                content: longContent
            )
        )
    }

    @Test
    func bubbleSessionGroupAndCloseHitRegionsNeverOverlap() {
        let sessions = (0 ..< 3).map { index in
            OverlaySessionContent(
                id: "session-\(index)",
                source: .codex,
                sessionID: "session-\(index)",
                eventType: .tool,
                sessionTitle: "Session \(index)",
                messageText: "正在运行",
                statusText: "正在使用工具"
            )
        }
        let content = OverlayBubbleContent(
            id: "agent-codex",
            source: .codex,
            agentName: "Codex",
            sessions: sessions,
            isExpanded: true
        )
        let size = OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 1512, height: 934),
            content: content
        )
        let bubble = CGRect(origin: .zero, size: size)
        let close = OverlayGeometry.bubbleCloseHitRect(in: bubble)
        let groupToggle = OverlayGeometry.bubbleGroupToggleHitRect(
            in: bubble,
            content: content
        )
        let sessionRects = OverlayGeometry.bubbleSessionRects(in: bubble, content: content)

        #expect(sessionRects.count == 3)
        #expect(!close.intersects(groupToggle))
        #expect(sessionRects.allSatisfy { !$0.intersects(close) })
        #expect(sessionRects.allSatisfy { !$0.intersects(groupToggle) })
    }

    @Test
    func collapsedAgentGroupKeepsLatestFirstAndRetainsAttentionSessions() throws {
        let older = try animationState(
            source: .codex,
            eventID: "older-failure",
            sessionID: "older-session",
            eventType: .failed,
            turnID: "older-turn",
            sourceEvent: "app_server_activity",
            sessionActivatedAt: "2026-07-20T00:00:00Z"
        )
        let newer = try animationState(
            source: .codex,
            eventID: "newer-tool",
            sessionID: "newer-session",
            eventType: .tool,
            turnID: "newer-turn",
            sourceEvent: "app_server_activity",
            sessionActivatedAt: "2026-07-20T00:01:00Z"
        )
        let collapsed = OverlayBubbleContent(
            source: .codex,
            states: [older, newer],
            isExpanded: false
        )
        let expanded = OverlayBubbleContent(
            source: .codex,
            states: [older, newer],
            isExpanded: true
        )

        #expect(collapsed.sessionCount == 2)
        #expect(
            collapsed.visibleSessions.map(\.sessionID)
                == ["newer-session", "older-session"]
        )
        #expect(
            collapsed.visibleSessions.filter { $0.sessionID == "older-session" }.count == 1
        )
        #expect(collapsed.statusTone == .failed)
        #expect(collapsed.isStacked)
        #expect(collapsed.stackDecorationDepth > 0)
        #expect(expanded.visibleSessions.map(\.sessionID) == ["newer-session", "older-session"])
        #expect(!expanded.isStacked)
        #expect(expanded.stackDecorationDepth == 0)
        let collapsedHeight = OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 1512, height: 934),
            content: collapsed
        ).height
        let expandedHeight = OverlayGeometry.resolvedBubbleSize(
            in: CGSize(width: 1512, height: 934),
            content: expanded
        ).height
        #expect(
            abs(collapsedHeight - expandedHeight - collapsed.stackDecorationDepth) < 0.001
        )
    }

    @Test
    func collapsedAgentGroupDeduplicatesLatestAttentionAndCapsAtEight() throws {
        var states: [ActiveAgentState] = []
        for index in 0 ..< 10 {
            let eventType: AgentEventKind = if index == 0 {
                .failed
            } else if index < 8 {
                index.isMultiple(of: 2) ? .failed : .waiting
            } else {
                .done
            }
            states.append(try animationState(
                source: .codex,
                eventID: "event-\(index)",
                sessionID: "session-\(index)",
                eventType: eventType,
                turnID: nil,
                sourceEvent: "app_server_activity",
                sessionActivatedAt: String(
                    format: "2026-07-20T00:%02d:00Z",
                    20 - index
                )
            ))
        }

        let content = OverlayBubbleContent(
            source: .codex,
            states: states,
            isExpanded: false
        )
        let visibleIDs = content.visibleSessions.compactMap(\.sessionID)

        #expect(content.sessionCount == 8)
        #expect(content.visibleSessions.count == 8)
        #expect(visibleIDs.first == "session-0")
        #expect(visibleIDs.filter { $0 == "session-0" }.count == 1)
        #expect(Set(visibleIDs).count == visibleIDs.count)
        #expect(content.visibleSessions.dropFirst().allSatisfy {
            $0.eventType == .waiting || $0.eventType == .failed
        })
    }

    @Test
    func legacySessionGroupPreservesPetCoreFirstSeenOrder() throws {
        let first = try animationState(
            source: .pi,
            eventID: "first-legacy",
            sessionID: "first-legacy",
            eventType: .tool,
            turnID: nil,
            sourceEvent: "tool_call",
            sessionActivatedAt: nil
        )
        let second = try animationState(
            source: .pi,
            eventID: "second-legacy",
            sessionID: "second-legacy",
            eventType: .failed,
            turnID: nil,
            sourceEvent: "agent_end",
            sessionActivatedAt: nil
        )

        let content = OverlayBubbleContent(
            source: .pi,
            states: [first, second],
            isExpanded: false
        )

        #expect(
            content.visibleSessions.map(\.sessionID)
                == ["first-legacy", "second-legacy"]
        )
        #expect(content.statusTone == .failed)
    }

    @Test
    func sessionGroupToneUsesAttentionFailureReadyRunningPriority() {
        func session(_ id: String, _ eventType: AgentEventKind) -> OverlaySessionContent {
            OverlaySessionContent(
                id: id,
                source: .codex,
                sessionID: id,
                eventType: eventType,
                sessionTitle: id,
                messageText: id,
                statusText: id
            )
        }

        let running = session("running", .tool)
        let ready = session("ready", .done)
        let failed = session("failed", .failed)
        let needsInput = session("needs-input", .waiting)

        #expect(OverlaySessionGroupTone.aggregate([running]) == .running)
        #expect(OverlaySessionGroupTone.aggregate([running, ready]) == .ready)
        #expect(OverlaySessionGroupTone.aggregate([running, ready, failed]) == .failed)
        #expect(
            OverlaySessionGroupTone.aggregate([running, ready, failed, needsInput])
                == .needsInput
        )
    }

    @Test
    func overlaySessionStatusCopyDistinguishesProtocolStates() {
        func status(_ eventType: AgentEventKind) -> String {
            OverlaySessionContent(event: AgentEvent(
                id: "status-\(eventType.rawValue)",
                source: .codex,
                sessionID: "status-copy",
                eventType: eventType,
                title: eventType.title,
                createdAt: "2026-07-21T00:00:00Z"
            )).statusText
        }

        #expect(status(.start) == APCLocalizedPresentation.lifecycleTitle(.start))
        #expect(status(.tool) == APCLocalizedPresentation.lifecycleTitle(.tool))
        #expect(status(.waiting) == APCLocalizedPresentation.lifecycleTitle(.waiting))
        #expect(status(.review) == APCLocalizedPresentation.lifecycleTitle(.review))
        #expect(status(.done) == APCLocalizedPresentation.lifecycleTitle(.done))
        #expect(status(.failed) == APCLocalizedPresentation.lifecycleTitle(.failed))
        #expect(status(.review) != status(.done))
    }

    @Test
    func onlyReviewAndDoneDismissAfterActivation() {
        func session(_ eventType: AgentEventKind) -> OverlaySessionContent {
            OverlaySessionContent(
                id: eventType.rawValue,
                source: .codex,
                sessionID: eventType.rawValue,
                eventType: eventType,
                sessionTitle: eventType.rawValue,
                messageText: eventType.rawValue,
                statusText: eventType.rawValue,
                navigation: AgentSessionNavigation(sessionOpen: false)
            )
        }

        #expect(!session(.start).dismissesAfterActivation)
        #expect(!session(.tool).dismissesAfterActivation)
        #expect(!session(.waiting).dismissesAfterActivation)
        #expect(session(.review).dismissesAfterActivation)
        #expect(session(.done).dismissesAfterActivation)
        #expect(!session(.failed).dismissesAfterActivation)
    }

    @MainActor
    @Test
    func activatingClosedRowsDismissesOnlyReviewAndDone() {
        let store = makeStore()
        let failed = OverlaySessionContent(
            id: "session-codex-failed",
            source: .codex,
            sessionID: "failed",
            eventType: .failed,
            sessionTitle: "Failed",
            messageText: "Blocked",
            statusText: "失败",
            navigation: AgentSessionNavigation(sessionOpen: false)
        )
        let waiting = OverlaySessionContent(
            id: "session-codex-waiting",
            source: .codex,
            sessionID: "waiting",
            eventType: .waiting,
            sessionTitle: "Waiting",
            messageText: "Needs input",
            statusText: "待确认",
            navigation: AgentSessionNavigation(sessionOpen: false)
        )
        let review = OverlaySessionContent(
            id: "session-codex-review",
            source: .codex,
            sessionID: "review",
            eventType: .review,
            sessionTitle: "Review",
            messageText: "Ready for review",
            statusText: "待审阅",
            navigation: AgentSessionNavigation(sessionOpen: false)
        )
        let done = OverlaySessionContent(
            id: "session-codex-done",
            source: .codex,
            sessionID: "done",
            eventType: .done,
            sessionTitle: "Done",
            messageText: "Completed",
            statusText: "已完成",
            navigation: AgentSessionNavigation(sessionOpen: false)
        )

        store.activateOverlaySession(failed)
        store.activateOverlaySession(waiting)
        #expect(store.overlayDismissedBubbleEventIDs.isEmpty)

        store.activateOverlaySession(review)
        store.activateOverlaySession(done)

        #expect(store.overlayDismissedBubbleEventIDs == [review.id, done.id])
    }

    @Test
    func dismissedAttentionStateFallsBackToTheNextVisiblePoseOrIdle() throws {
        let review = try animationState(
            source: .codex,
            eventID: "review-old",
            sessionID: "review-session",
            eventType: .review,
            turnID: "turn-review",
            sourceEvent: "PostToolUse",
            sessionActivatedAt: "2026-07-17T00:00:00Z"
        )
        let running = try animationState(
            source: .pi,
            eventID: "tool-visible",
            sessionID: "tool-session",
            eventType: .tool,
            turnID: "turn-tool",
            sourceEvent: "tool_execution_start",
            sessionActivatedAt: "2026-07-17T00:01:00Z"
        )
        let dismissedReviewID = OverlaySessionContent.stableID(
            source: review.source,
            sessionID: review.sessionID,
            fallbackEventID: review.event.id
        )

        #expect(OverlayPresentedAgentState.resolve(
            canonicalState: review,
            activeSessions: [review, running],
            dismissedSessionIDs: [dismissedReviewID]
        ) == running)

        for eventType in [AgentEventKind.waiting, .failed] {
            let attention = try animationState(
                source: .claudeCode,
                eventID: "\(eventType.rawValue)-old",
                sessionID: "\(eventType.rawValue)-session",
                eventType: eventType,
                turnID: nil,
                sourceEvent: "attention",
                sessionActivatedAt: "2026-07-17T00:02:00Z"
            )
            let dismissalID = OverlaySessionContent.stableID(
                source: attention.source,
                sessionID: attention.sessionID,
                fallbackEventID: attention.event.id
            )
            #expect(OverlayPresentedAgentState.resolve(
                canonicalState: attention,
                activeSessions: [attention],
                dismissedSessionIDs: [dismissalID]
            ) == nil)
        }
    }

    @Test
    func aNewAttentionEventReopensItsLocallyDismissedSession() throws {
        let oldReview = try animationState(
            source: .codex,
            eventID: "review-old",
            sessionID: "review-session",
            eventType: .review,
            turnID: "turn-old",
            sourceEvent: "PostToolUse",
            sessionActivatedAt: "2026-07-17T00:00:00Z"
        )
        let newReview = try animationState(
            source: .codex,
            eventID: "review-new",
            sessionID: "review-session",
            eventType: .review,
            turnID: "turn-new",
            sourceEvent: "PostToolUse",
            sessionActivatedAt: "2026-07-17T00:01:00Z"
        )
        let dismissalID = OverlaySessionContent.stableID(
            source: oldReview.source,
            sessionID: oldReview.sessionID,
            fallbackEventID: oldReview.event.id
        )
        let reopened = OverlayPresentedAgentState.newlyActivatedDismissalIDs(
            activeSessions: [newReview],
            knownReopenIDs: [OverlaySessionContent.reopenID(for: oldReview)]
        )
        var dismissedIDs: Set<String> = [dismissalID]
        dismissedIDs.subtract(reopened)

        #expect(reopened == [dismissalID])
        #expect(dismissedIDs.isEmpty)
        #expect(OverlayPresentedAgentState.resolve(
            canonicalState: newReview,
            activeSessions: [newReview],
            dismissedSessionIDs: dismissedIDs
        ) == newReview)
    }

    @MainActor
    @Test
    func agentGroupUsesTheConfiguredDefaultAndAllowsATemporaryOverride() {
        let store = makeStore()
        store.behavior.sessionGroupDisplay = .stacked
        #expect(!store.overlayAgentGroupIsExpanded(.codex))

        store.toggleOverlayAgentGroup(.codex)
        #expect(store.overlayAgentGroupIsExpanded(.codex))

        let expandedStore = makeStore()
        expandedStore.behavior.sessionGroupDisplay = .expanded
        #expect(expandedStore.overlayAgentGroupIsExpanded(.opencode))
    }

    @MainActor
    @Test
    func expandingBubblePreservesConsumedSessionDismissals() {
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
        #expect(
            store.overlayDismissedBubbleEventIDs
                == ["codex-session-event", "pi-session-event"]
        )
    }

    @MainActor
    @Test
    func revealingBubbleWithoutSessionContentIsANoOp() {
        let store = makeStore()
        store.overlayBubbleDismissed = true

        store.revealOverlayBubble()
        #expect(store.overlayBubbleDismissed)

        store.revealOverlayBubble()
        #expect(store.overlayBubbleDismissed)
    }

    @MainActor
    @Test
    func pointerMonitorClearsLostDragAndResizeMouseUpState() {
        let store = makeStore()
        store.setOverlayPetDragInProgress(true)
        store.setOverlayResizeInProgress(true)

        store.reconcileOverlayPointerInteractions(pressedMouseButtons: 1)
        #expect(store.overlayPetDragInProgress)
        #expect(store.overlayResizeInProgress)

        store.reconcileOverlayPointerInteractions(pressedMouseButtons: 0)
        #expect(!store.overlayPetDragInProgress)
        #expect(!store.overlayResizeInProgress)
    }

    @Test
    func agentSessionRouterEnforcesDeclaredAndStructurallyValidCapabilities() throws {
        let warpURL = "warp://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4"
        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-1",
                navigation: AgentSessionNavigation(
                    capability: .exactSession,
                    sessionOpen: true,
                    surface: "cli_terminal",
                    terminalApp: "warp",
                    openURL: warpURL
                )
            ) == .url(try #require(URL(string: warpURL)))
        )
        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-1",
                navigation: AgentSessionNavigation(
                    capability: .exactSession,
                    sessionOpen: true,
                    surface: "chatgpt_app",
                    terminalApp: "warp",
                    openURL: warpURL
                )
            ) == nil
        )

        let unconfirmedDesktopThread = try #require(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-unconfirmed",
                navigation: AgentSessionNavigation(
                    capability: .agentHost,
                    sessionOpen: nil,
                    surface: "chatgpt_app"
                )
            )
        )
        guard case .application = unconfirmedDesktopThread else {
            Issue.record("unconfirmed Codex hook sessions must only activate ChatGPT")
            return
        }

        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "ses-opaque-thread",
                navigation: AgentSessionNavigation(
                    capability: .exactSession,
                    sessionOpen: true,
                    surface: "chatgpt_app",
                    routableSessionID: "019f5b0f-88ff-7413-8953-29de4ed0951c"
                )
            ) == .url(try #require(URL(
                string: "codex://threads/019f5b0f-88ff-7413-8953-29de4ed0951c"
            )))
        )

        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-confirmed",
                navigation: AgentSessionNavigation(
                    capability: .exactSession,
                    sessionOpen: true,
                    surface: "chatgpt_app"
                )
            ) == nil
        )

        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "019f5b0f-88ff-7413-8953-29de4ed0951c",
                navigation: AgentSessionNavigation(
                    capability: .exactSession,
                    sessionOpen: true,
                    surface: "chatgpt_app"
                )
            ) == nil
        )

        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-1",
                navigation: AgentSessionNavigation(
                    capability: .agentHost,
                    sessionOpen: true
                )
            )
            == nil
        )

        #expect(
            AgentSessionRouter.route(
                source: .pi,
                sessionID: "terminal-host",
                navigation: AgentSessionNavigation(
                    capability: .agentHost,
                    sessionOpen: true,
                    surface: "cli_terminal"
                )
            ) == nil
        )

        let knownTerminal = try #require(
            AgentSessionRouter.route(
                source: .pi,
                sessionID: "terminal-host",
                navigation: AgentSessionNavigation(
                    capability: .agentHost,
                    sessionOpen: true,
                    surface: "cli_terminal",
                    terminalApp: "ghostty"
                )
            )
        )
        guard case let .application(bundleIdentifiers, paths) = knownTerminal else {
            Issue.record("a structurally valid host route must activate its declared terminal")
            return
        }
        #expect(bundleIdentifiers == ["com.mitchellh.ghostty"])
        #expect(paths == ["/Applications/Ghostty.app"])

        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-1",
                navigation: AgentSessionNavigation(
                    capability: .agentHost,
                    sessionOpen: false
                )
            ) == nil
        )
        #expect(
            AgentSessionRouter.route(
                source: .codex,
                sessionID: "thread-1",
                navigation: AgentSessionNavigation(
                    capability: .unavailable,
                    sessionOpen: true,
                    surface: "chatgpt_app"
                )
            ) == nil
        )
    }

    @Test
    func overlayNavigationCopyAndAccessibilityMatchTheValidatedDestination() {
        func session(
            id: String,
            navigation: AgentSessionNavigation
        ) -> OverlaySessionContent {
            OverlaySessionContent(
                id: id,
                source: .codex,
                sessionID: id,
                eventType: .waiting,
                sessionTitle: id,
                messageText: "Needs a response",
                statusText: "Needs You",
                navigation: navigation
            )
        }

        let exact = session(
            id: "exact",
            navigation: AgentSessionNavigation(
                capability: .exactSession,
                sessionOpen: true,
                surface: "cli_terminal",
                terminalApp: "warp",
                openURL: "warp://session/A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4"
            )
        )
        let host = session(
            id: "host",
            navigation: AgentSessionNavigation(
                capability: .agentHost,
                sessionOpen: true,
                surface: "chatgpt_app"
            )
        )
        let unavailable = session(
            id: "unavailable",
            navigation: AgentSessionNavigation(
                capability: .exactSession,
                sessionOpen: true,
                surface: "chatgpt_app",
                routableSessionID: "malformed"
            )
        )
        let content = OverlayBubbleContent(
            id: "agent-codex",
            source: .codex,
            agentName: "Codex",
            sessions: [exact, host, unavailable]
        )
        let accessibility = OverlayBubbleAccessibilityModel(
            content: content,
            locale: "en"
        )

        #expect(exact.navigationCapability == .exactSession)
        #expect(exact.actionLabel == APCLocalizedPresentation.navigationActionTitle(
            .exactSession,
            source: .codex
        ))
        #expect(host.navigationCapability == .agentHost)
        #expect(host.actionLabel == APCLocalizedPresentation.navigationActionTitle(
            .agentHost,
            source: .codex
        ))
        #expect(unavailable.navigationCapability == .unavailable)
        #expect(!unavailable.canOpen)
        #expect(exact.accessibilityReadingOrder == [
            "Codex",
            "exact",
            "Needs You",
            "Needs a response",
            APCLocalizedPresentation.navigationActionTitle(
                .exactSession,
                source: .codex
            )!,
        ])
        #expect(accessibility.sessionActionLabels == [
            "Return to Session",
            "Open Codex",
            nil,
        ])
    }

    @Test
    func overlayPresentationSuppressesRepeatedTitleStatusAndMessage() throws {
        let state = try JSONDecoder().decode(
            ActiveAgentState.self,
            from: Data(
                #"{"state":"tool","source":"codex","session_id":"deduplicated","source_session_sequence":1,"priority":300,"event":{"id":"deduplicated-event","source":"codex","session_id":"deduplicated","event_type":"tool","title":"Working","created_at":"2026-07-23T00:00:00Z"},"session_title":"Working","session_message":{"role":"assistant","content":"Working"}}"#.utf8
            )
        )
        let content = OverlaySessionContent(state: state)

        #expect(content.sessionTitle != content.statusText)
        #expect(content.messageText != content.statusText)
        #expect(content.messageText != content.sessionTitle)
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

    @Test
    func transparentBubbleGlassUsesTheRegularNativeBaselineAndHonorsAccessibility() {
        #expect(APCBubbleGlassStyle.backdropOpacity == 0)
        #expect(APCBubbleGlassStyle.borderOpacity == 0)
        #expect(
            APCBubbleGlassStyle.opticalOpacity(for: 0)
                > APCBubbleGlassStyle.opticalOpacity(for: 1)
        )
        #expect(
            abs(
                APCBubbleGlassStyle.opticalOpacity(for: 1)
                    - APCBubbleGlassStyle.minimumOpticalOpacity
            ) < 0.000_1
        )
        #expect(APCBubbleGlassStyle.opticalOpacity(for: 0.55) > 0.50)
        #expect(
            APCBubbleGlassStyle.resolvedBackdropOpacity(
                reduceTransparency: false,
                increasedContrast: false
            ) == APCBubbleGlassStyle.backdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.resolvedBackdropOpacity(
                reduceTransparency: false,
                increasedContrast: true
            ) > APCBubbleGlassStyle.backdropOpacity
        )
        #expect(
            APCBubbleGlassStyle.resolvedBackdropOpacity(
                reduceTransparency: true,
                increasedContrast: false
            ) >= 0.80
        )
        #expect(
            APCBubbleGlassStyle.resolvedBorderOpacity(
                reduceTransparency: false,
                increasedContrast: false,
                supportsLiquidGlass: true
            ) == 0
        )
        #expect(
            APCBubbleGlassStyle.resolvedBorderOpacity(
                reduceTransparency: false,
                increasedContrast: false,
                supportsLiquidGlass: false
            ) > 0
        )
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

    private func animationState(
        source: AgentSource,
        eventID: String,
        sessionID: String,
        eventType: AgentEventKind,
        turnID: String?,
        sourceEvent: String,
        messageRole: String? = nil,
        sessionActivatedAt: String?
    ) throws -> ActiveAgentState {
        var payloadObject: [String: Any] = [
            "source_event": sourceEvent,
            "session_active": true
        ]
        if let turnID {
            payloadObject["turn_id"] = turnID
        }
        if let messageRole {
            payloadObject["message_role"] = messageRole
        }
        let payload = try JSONDecoder().decode(
            AgentEventPayload.self,
            from: JSONSerialization.data(withJSONObject: payloadObject)
        )
        let event = AgentEvent(
            id: eventID,
            source: source,
            sessionID: sessionID,
            eventType: eventType,
            title: eventType.title,
            payloadJSON: payload,
            createdAt: "2026-07-17T00:00:30Z"
        )
        let projectedStateEntryID: String
        switch eventType {
        case .tool, .waiting, .review, .failed:
            projectedStateEntryID = eventType.rawValue
        case .start, .done:
            let marker = sessionActivatedAt
                ?? (eventType == .done ? turnID : nil)
                ?? "initial"
            projectedStateEntryID = [
                eventType.rawValue,
                source.rawValue,
                sessionID,
                marker
            ].joined(separator: ":")
        }
        let summaryKind: AgentOverlaySummaryKind = switch eventType {
        case .start: .running
        case .tool: .tool
        case .waiting: .needsInput
        case .review: .review
        case .done: .done
        case .failed: .failed
        }
        return ActiveAgentState(
            state: eventType.rawValue,
            officialStatus: "running",
            source: source,
            sessionID: sessionID,
            sessionActive: true,
            sourceSessionSequence: 1,
            priority: 300,
            leaseSeconds: nil,
            expiresAt: nil,
            sessionActivatedAt: sessionActivatedAt,
            event: event,
            latestMessage: nil,
            latestUserMessage: nil,
            sessionTitle: nil,
            sessionMessage: nil,
            sessionUserMessage: nil,
            sessionActivity: nil,
            overlayDisplay: AgentOverlayDisplay(
                summaryKind: summaryKind,
                stateEntryID: projectedStateEntryID
            )
        )
    }

    @MainActor
    private func makeStore() -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
    }
}
