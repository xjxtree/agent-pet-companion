import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite
struct BehaviorSettingsViewTests {
    @Test
    func configurationHasExactlyTwoStableSubpages() {
        #expect(BehaviorSettingsSection.allCases == [.appearance, .messages])
        #expect(
            BehaviorSettingsSection.allCases.map(\.title)
                == [
                    APCLocalization.text(.configSectionAppearance),
                    APCLocalization.text(.configSectionMessages),
                ]
        )
    }

    @Test
    func messageCatalogContainsOnlyTheSupportedSourcesAndEvents() {
        #expect(BehaviorSettingsCatalog.sources == [.codex, .claudeCode, .pi, .opencode])
        #expect(
            BehaviorSettingsCatalog.events
                == [.start, .thinking, .plan, .tool, .waiting, .done, .failed]
        )
    }

    @Test
    func appearanceCatalogKeepsTheClosedLanguageThemeAndGroupingOptions() {
        #expect(BehaviorSettingsCatalog.interfaceLanguages == [
            .system,
            .english,
            .simplifiedChinese,
        ])
        #expect(BehaviorSettingsCatalog.appearanceThemes == [.system, .light, .dark])
        #expect(BehaviorSettingsCatalog.groupDisplays == [.stacked, .expanded])
        #expect(BehaviorSettingsCatalog.bubbleFontScales == [.standard, .large])
    }

    @Test
    func bubbleFontScaleOffersExactlyTwoTiersWithStandardAsTheCurrentSize() {
        #expect(BubbleFontScale.allCases == [.standard, .large])
        #expect(BehaviorSettings().bubbleFontScale == .standard)
        #expect(BubbleFontScale.standard.multiplier == 1)
        #expect(BubbleFontScale.large.multiplier == 1.15)
        #expect(
            APCLocalizedPresentation.bubbleFontScaleTitle(.standard, locale: "en") == "Standard"
        )
        #expect(
            APCLocalizedPresentation.bubbleFontScaleTitle(.large, locale: "zh-Hans") == "更大"
        )
    }

    @Test
    func bubbleFontScalePersistsThroughBehaviorEncodingAndPatchDiff() throws {
        var large = BehaviorSettings()
        large.bubbleFontScale = .large
        let encoded = try JSONEncoder().encode(large)
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(json["bubble_font_scale"] as? String == "large")
        #expect(
            try JSONDecoder().decode(BehaviorSettings.self, from: encoded).bubbleFontScale
                == .large
        )

        // A stored payload written before this setting existed keeps rendering
        // at the standard tier instead of failing to decode.
        let legacy = try JSONDecoder().decode(
            BehaviorSettings.self,
            from: Data(#"{"enabled":true}"#.utf8)
        )
        #expect(legacy.bubbleFontScale == .standard)

        let patch = BehaviorSettingsPatch(from: BehaviorSettings(), to: large)
        #expect(patch.bubbleFontScale == .large)
        #expect(!patch.isEmpty)
        #expect(BehaviorSettingsPatch(from: large, to: large).bubbleFontScale == nil)
        let patchJSON = try #require(
            try JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(patch)
            ) as? [String: Any]
        )
        #expect(patchJSON["bubble_font_scale"] as? String == "large")
    }

    @Test
    func messageAttentionOptionsExposeThreePresetsAndDerivedCustomOnly() {
        let standard = BehaviorSettingsCatalog.attentionPresetOptions(
            selection: .standard,
            locale: "en"
        )
        #expect(standard.map(\.preset) == [
            .onlyWhenNeeded,
            .standard,
            .allActivity,
        ])
        #expect(standard.allSatisfy { $0.isSelectable })
        #expect(standard[0].detail.contains("Waiting for You"))
        #expect(standard[0].detail.contains("Failed"))
        #expect(!standard[0].detail.contains("Thinking"))
        #expect(standard[1].detail.contains("Thinking"))
        #expect(!standard[1].detail.contains("Using Tools"))
        #expect(standard[2].detail.contains("Using Tools"))

        let custom = BehaviorSettingsCatalog.attentionPresetOptions(
            selection: .custom,
            locale: "zh-Hans"
        )
        #expect(custom.map(\.preset) == [
            .onlyWhenNeeded,
            .standard,
            .allActivity,
            .custom,
        ])
        #expect(custom.last?.isSelectable == false)
        #expect(custom.last?.detail.contains("高级消息设置") == true)
    }

    @Test
    func sourceSummaryReusesTheConnectionProductProjectionAndIgnoresProjectCompatibilityChecks() {
        let status = connectionStatus(items: [
            connectionItem(.ok, code: .managedConnector),
            connectionItem(.ok, code: .eventDelivery),
            connectionItem(.ok, code: .hostVerification),
            connectionItem(
                .missing,
                code: .projectDirectory,
                recovery: .chooseProjectDirectory
            ),
        ])
        let connection = AgentConnectionProductPresentation(
            source: .codex,
            status: status,
            operationState: .idle
        )

        #expect(connection.health == .connected)
        #expect(
            ConfigurationSourcePresentation.detail(
                source: .codex,
                status: status,
                operationState: .idle,
                localeIdentifier: "en"
            )
                == APCLocalizedPresentation.connectionHealthTitle(
                    connection.health,
                    locale: "en"
                )
        )
        #expect(
            ConfigurationSourcePresentation.detail(
                source: .codex,
                status: status,
                operationState: .idle,
                localeIdentifier: "en"
            ) == "Connected"
        )
    }

    @Test
    func sourceSummaryFailsClosedForUnknownConnectionChecks() {
        let status = connectionStatus(items: [
            connectionItem(.ok, code: .managedConnector),
            connectionItem(.ok, code: .unknown),
        ])
        let connection = AgentConnectionProductPresentation(
            source: .codex,
            status: status,
            operationState: .idle
        )

        #expect(connection.health == .notChecked)
        #expect(
            ConfigurationSourcePresentation.detail(
                source: .codex,
                status: status,
                operationState: .idle,
                localeIdentifier: "en"
            ) == "Not Checked"
        )
    }

    @Test
    func configurationUsesAnInPageSwitchWithoutAPermanentSettingsSidebar() throws {
        let source = try String(
            contentsOf: viewsDirectory.appendingPathComponent(
                "BehaviorSettingsView.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains("LayoutPreservingHorizontalSeparatorGap()"))
        #expect(source.contains("private var settingsColumn: some View"))
        #expect(!source.contains("showsInlinePreview"))
        #expect(!source.contains("BehaviorAppearancePreview"))
        #expect(!source.contains("BehaviorMessagePreview"))
        #expect(!source.contains("configuration.preview-pane"))
        #expect(!source.contains("BehaviorSettingsSubnavigation"))
        #expect(!source.contains("configuration.subnavigation"))
        #expect(!source.contains("navigationWidth"))
        #expect(!source.contains("configuration.preview.resize-handle"))
        #expect(source.contains("Text(APCLocalization.text(.configSizeFooter))"))
        #expect(source.contains("\"configuration.appearance.language\""))
        #expect(source.contains("\"configuration.messages.group-by-agent\""))
        #expect(source.contains("behaviorBinding(\\.groupSessionsByAgent)"))
        let grouping = try #require(source.range(of: "sessionGroupingSetting"))
        let groupDisplay = try #require(
            source.range(
                of: "sessionGroupDisplaySetting",
                range: grouping.upperBound ..< source.endIndex
            )
        )
        let advancedMessages = try #require(
            source.range(
                of: "AdvancedDetailsDisclosure(",
                range: groupDisplay.upperBound ..< source.endIndex
            )
        )
        #expect(groupDisplay.lowerBound < advancedMessages.lowerBound)
        #expect(!source.contains("bubbleTransparencySetting"))
        #expect(!source.contains("configuration.appearance.bubble-transparency"))
        #expect(!source.contains("bubbleTransparencyDraft"))
        #expect(!source.contains("configuration.appearance.mouse-passthrough"))
        #expect(!source.contains("configMousePassthrough"))
    }

    @Test
    func sidebarPreviewUsesTheDefaultFlatFoldedSessionStack() throws {
        let presentation = SidebarConfigurationPreviewPresentation(
            behavior: BehaviorSettings(),
            localeIdentifier: "en"
        )
        let content = try #require(presentation.contents.first)

        #expect(presentation.contents.count == 1)
        #expect(presentation.emptyReason == nil)
        #expect(content.source == .codex)
        #expect(content.isStandaloneSessionCard)
        #expect(content.sessions.count == 1)
        #expect(content.visibleSessions.count == 1)
        #expect(content.disclosureSessionCount == 2)
        #expect(content.isStacked)
        #expect(content.showsStackDecoration)
        #expect(content.sessions.map(\.eventType) == [.waiting])
        #expect(presentation.petAction == .waiting)
    }

    @Test
    func sidebarPreviewExpandsAgentSessionsAndPreservesTheirStateMessages() throws {
        var behavior = BehaviorSettings()
        behavior.groupSessionsByAgent = true
        behavior.sessionGroupDisplay = .expanded
        let presentation = SidebarConfigurationPreviewPresentation(
            behavior: behavior,
            localeIdentifier: "zh-Hans"
        )
        let content = try #require(presentation.contents.first)

        #expect(content.visibleSessions.count == 2)
        #expect(!content.isStacked)
        #expect(content.visibleSessions[0].statusText == "等待你操作")
        #expect(content.visibleSessions[0].messageText.contains("必须等你"))
        #expect(content.visibleSessions[1].statusText == "执行失败")
        #expect(content.visibleSessions[1].messageText == "任务执行失败")
    }

    @Test
    func sidebarPreviewUsesTheSamePreferenceForTheGlobalSessionStack() throws {
        var behavior = BehaviorSettings()
        behavior.groupSessionsByAgent = false

        let stacked = SidebarConfigurationPreviewPresentation(
            behavior: behavior,
            localeIdentifier: "en"
        )
        let stack = try #require(stacked.contents.first)
        #expect(stacked.contents.count == 1)
        #expect(stack.isStandaloneSessionCard)
        #expect(stack.disclosureSessionCount == 2)
        #expect(stack.isStacked)

        behavior.sessionGroupDisplay = .expanded
        let expanded = SidebarConfigurationPreviewPresentation(
            behavior: behavior,
            localeIdentifier: "en"
        )
        #expect(expanded.contents.count == 2)
        #expect(expanded.contents.allSatisfy { $0.isStandaloneSessionCard })
        #expect(expanded.contents.allSatisfy { !$0.isStacked })
        #expect(expanded.contents.compactMap(\.source) == [.codex, .claudeCode])
    }

    @Test
    func sidebarPreviewIgnoresDesktopVisibilityAndExplainsBubbleSuppression() {
        var behavior = BehaviorSettings()
        behavior.enabled = false
        let hiddenDesktopPresentation = SidebarConfigurationPreviewPresentation(
            behavior: behavior
        )
        #expect(hiddenDesktopPresentation.emptyReason == nil)
        #expect(!hiddenDesktopPresentation.contents.isEmpty)
        #expect(hiddenDesktopPresentation.petAction == .waiting)

        behavior.statusBubble = false
        #expect(
            SidebarConfigurationPreviewPresentation(behavior: behavior).emptyReason
                == .bubbleHidden
        )

        behavior.statusBubble = true
        behavior.sources = Dictionary(
            uniqueKeysWithValues: AgentSource.allCases.map { ($0, false) }
        )
        #expect(
            SidebarConfigurationPreviewPresentation(behavior: behavior).emptyReason
                == .noSources
        )

        behavior.sources[.codex] = true
        behavior.events = Dictionary(
            uniqueKeysWithValues: AgentEventKind.allCases.map { ($0, false) }
        )
        #expect(
            SidebarConfigurationPreviewPresentation(behavior: behavior).emptyReason
                == .noEvents
        )
    }

    @Test
    func sidebarPreviewImmediatelyUsesTheEnabledSourceAndEvent() throws {
        var behavior = BehaviorSettings()
        behavior.sources = Dictionary(
            uniqueKeysWithValues: AgentSource.allCases.map { ($0, false) }
        )
        behavior.sources[.pi] = true
        behavior.events = Dictionary(
            uniqueKeysWithValues: AgentEventKind.allCases.map { ($0, false) }
        )
        behavior.events[.done] = true

        let presentation = SidebarConfigurationPreviewPresentation(
            behavior: behavior,
            localeIdentifier: "en"
        )
        let content = try #require(presentation.contents.first)

        #expect(content.source == .pi)
        #expect(content.sessions.map(\.source) == [.pi])
        #expect(content.sessions.map(\.eventType) == [.done])
        #expect(content.disclosureSessionCount == 2)
        #expect(content.sessions.allSatisfy { $0.statusText == "Completed" })
        #expect(presentation.petAction == .done)
    }

    @Test
    func sidebarPetPreviewScalesTheFullDisplayWidthRangeIntoItsBoundedStage() {
        #expect(
            SidebarConfigurationPreviewLayout.petWidth(displayWidthPt: 100)
                == SidebarConfigurationPreviewLayout.minimumPetWidth
        )
        #expect(
            SidebarConfigurationPreviewLayout.petWidth(displayWidthPt: 300)
                == SidebarConfigurationPreviewLayout.maximumPetWidth
        )
        #expect(
            SidebarConfigurationPreviewLayout.petWidth(displayWidthPt: -1)
                == SidebarConfigurationPreviewLayout.minimumPetWidth
        )
        #expect(
            SidebarConfigurationPreviewLayout.petWidth(displayWidthPt: 1_000)
                == SidebarConfigurationPreviewLayout.maximumPetWidth
        )
    }

    @MainActor
    @Test
    func rapidBehaviorWritesSerializeExpectedRevisionsAndKeepTheLatestResult() async throws {
        let probe = BehaviorPersistenceProbe()
        let store = makeStore(probe: probe)
        var first = store.behavior
        first.autoHide = true
        store.updateBehavior(first)

        var second = store.behavior
        second.appearanceTheme = .dark
        store.updateBehavior(second)
        await store.waitForBehaviorPersistence()

        #expect(probe.expectedRevisions == ["0", "1"])
        #expect(probe.serverRevision == "2")
        #expect(probe.serverBehavior.autoHide)
        #expect(probe.serverBehavior.appearanceTheme == .dark)
        #expect(store.behavior == probe.serverBehavior)
        #expect(store.behaviorRevision == "2")
    }

    @MainActor
    @Test
    func languageChoiceAppliesImmediatelyAndPersistsThroughBehaviorSettings() async throws {
        let probe = BehaviorPersistenceProbe()
        var appliedLanguages: [InterfaceLanguage] = []
        let store = makeStore(
            probe: probe,
            applicationLanguageApplier: { language in
                appliedLanguages.append(language)
            }
        )
        var next = store.behavior
        next.interfaceLanguage = .simplifiedChinese

        store.updateBehavior(next)

        #expect(appliedLanguages == [.simplifiedChinese])
        #expect(store.behavior.interfaceLanguage == .simplifiedChinese)
        #expect(store.interfaceLocaleIdentifier == "zh-Hans")

        await store.waitForBehaviorPersistence()

        #expect(probe.serverBehavior.interfaceLanguage == .simplifiedChinese)
        #expect(store.behavior == probe.serverBehavior)
        #expect(store.behaviorRevision == "1")
    }

    @MainActor
    @Test
    func queuedBehaviorWriteBlocksAppHandoffUntilItIsPersisted() async throws {
        let gate = BehaviorPersistenceGate()
        var persisted = BehaviorSettings()
        persisted.autoHide = true
        let persistedObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(persisted)
        )
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            petCoreRequestOverride: { method, _, _ in
                guard method == "behavior.patch" else {
                    throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
                }
                await gate.wait()
                return [
                    "behavior": persistedObject,
                    "revision": "1",
                ]
            }
        )

        store.updateBehavior(persisted)
        await gate.waitUntilBlocked()
        #expect(!store.isSafeForAppUpdateHandoff)

        await gate.open()
        await store.waitForBehaviorPersistence()
        #expect(store.isSafeForAppUpdateHandoff)
    }

    @MainActor
    @Test
    func revisionConflictRefreshesAndRetriesWithoutLosingTheLocalChoice() async throws {
        var remote = BehaviorSettings()
        remote.appearanceTheme = .dark
        let probe = BehaviorPersistenceProbe(
            serverBehavior: remote,
            serverRevision: "5",
            conflictCount: 1
        )
        let store = makeStore(probe: probe)
        var next = store.behavior
        next.autoHide = true
        store.updateBehavior(next)
        await store.waitForBehaviorPersistence()

        #expect(probe.expectedRevisions == ["0", "5"])
        #expect(probe.snapshotRequestCount == 1)
        #expect(store.behavior.appearanceTheme == .dark)
        #expect(store.behavior.autoHide)
        #expect(store.behavior == probe.serverBehavior)
        #expect(store.behaviorRevision == "6")
    }

    @MainActor
    @Test
    func failedBehaviorWriteRollsBackToTheAuthoritativeSnapshot() async throws {
        var remote = BehaviorSettings()
        remote.sessionMessageTimeoutMinutes = 45
        let probe = BehaviorPersistenceProbe(
            serverBehavior: remote,
            serverRevision: "7",
            failureCount: 1
        )
        let store = makeStore(probe: probe)
        var next = store.behavior
        next.sessionMessageTimeoutMinutes = 90
        store.updateBehavior(next)
        #expect(store.behavior.sessionMessageTimeoutMinutes == 90)

        await store.waitForBehaviorPersistence()

        #expect(probe.expectedRevisions == ["0"])
        #expect(probe.snapshotRequestCount == 1)
        #expect(store.behavior == remote)
        #expect(store.behaviorRevision == "7")
    }

    @MainActor
    private func makeStore(
        probe: BehaviorPersistenceProbe,
        applicationLanguageApplier: @escaping AppStore.ApplicationLanguageApplier = { _ in }
    ) -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { _ in },
            applicationLanguageApplier: applicationLanguageApplier,
            petCoreRequestOverride: { method, params, _ in
                try probe.handle(method: method, params: params)
            }
        )
    }

    private var viewsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion/Views", isDirectory: true)
    }

    private static func snapshotPayload(
        behavior: BehaviorSettings,
        revision: String
    ) throws -> [String: Any] {
        let data = try JSONEncoder().encode(behavior)
        let behaviorObject = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return [
            "revision": "state-\(revision)",
            "overlay_placement_revision": "0",
            "behavior": behaviorObject,
            "behavior_revision": revision,
            "pets": [],
            "active_agent_sessions": [],
            "active_agent_sessions_omitted_count": 0,
            "events": [],
            "recent_events": [],
            "connections": [],
        ]
    }

    private func connectionStatus(
        items: [ConnectionCheckItem]
    ) -> AgentConnectionStatus {
        AgentConnectionStatus(
            source: .codex,
            items: items,
            installPaths: [],
            connectorInstalled: true,
            checkMode: .runtime,
            verification: AgentVerification(
                status: .verified,
                title: "untrusted",
                detail: "untrusted"
            ),
            capabilities: AgentConnectorCapabilities(
                contractVersion: "typed-test-v1",
                subscribedEvents: [],
                mappedInformation: [],
                privacyExclusions: [],
                repairableConnectorIssue: false,
                canRepairManagedConnector: true,
                managedPathConflict: false,
                canUninstallManagedConnector: false
            )
        )
    }

    private func connectionItem(
        _ status: CheckStatus,
        code: ConnectionCheckCode,
        recovery: ConnectionCheckRecoveryKind? = nil
    ) -> ConnectionCheckItem {
        ConnectionCheckItem(
            code: code,
            name: "untrusted",
            status: status,
            detail: "untrusted",
            recoveryAction: recovery
        )
    }
}

@MainActor
private final class BehaviorPersistenceProbe {
    var serverBehavior: BehaviorSettings
    var serverRevision: String
    var conflictCount: Int
    var failureCount: Int
    var expectedRevisions: [String] = []
    var snapshotRequestCount = 0

    init(
        serverBehavior: BehaviorSettings = BehaviorSettings(),
        serverRevision: String = "0",
        conflictCount: Int = 0,
        failureCount: Int = 0
    ) {
        self.serverBehavior = serverBehavior
        self.serverRevision = serverRevision
        self.conflictCount = conflictCount
        self.failureCount = failureCount
    }

    func handle(method: String, params: Any) throws -> Any {
        switch method {
        case "behavior.patch":
            return try handleBehaviorPatch(params)
        case "state.snapshot":
            snapshotRequestCount += 1
            return try snapshot()
        case "generation.latest":
            return ["found": false]
        case "overlay.placement.update":
            var placement = try #require(params as? [String: Any])
            let expected = try #require(
                placement.removeValue(forKey: "expected_revision") as? String
            )
            let next = (UInt64(expected) ?? 0) + 1
            return [
                "ok": true,
                "revision": "state-overlay-\(next)",
                "overlay_placement_revision": String(next),
                "overlay_placement": placement,
                "overlay_placement_intent": NSNull(),
            ]
        default:
            throw PetCoreClientError.rpcError("Unexpected test RPC: \(method)")
        }
    }

    private func handleBehaviorPatch(_ params: Any) throws -> Any {
        let parameters = try #require(params as? [String: Any])
        let expectedRevision = try #require(
            parameters["expected_revision"] as? String
        )
        expectedRevisions.append(expectedRevision)

        if conflictCount > 0 {
            conflictCount -= 1
            throw PetCoreClientError.rpcError("behavior revision conflict")
        }
        if failureCount > 0 {
            failureCount -= 1
            throw PetCoreClientError.connectFailed("offline")
        }
        #expect(expectedRevision == serverRevision)

        let changes = try #require(parameters["changes"] as? [String: Any])
        var encoded = try jsonObject(serverBehavior)
        for (key, value) in changes {
            if key == "sources" || key == "events" {
                var merged = encoded[key] as? [String: Any] ?? [:]
                for (entry, enabled) in try #require(value as? [String: Any]) {
                    merged[entry] = enabled
                }
                encoded[key] = merged
            } else {
                encoded[key] = value
            }
        }
        let data = try JSONSerialization.data(withJSONObject: encoded)
        serverBehavior = try JSONDecoder().decode(BehaviorSettings.self, from: data)
        serverRevision = String((Int(serverRevision) ?? 0) + 1)
        return [
            "behavior": try jsonObject(serverBehavior),
            "revision": serverRevision,
        ]
    }

    private func snapshot() throws -> [String: Any] {
        [
            "revision": "state-\(serverRevision)",
            "overlay_placement_revision": "0",
            "behavior": try jsonObject(serverBehavior),
            "behavior_revision": serverRevision,
            "pets": [],
            "active_agent_sessions": [],
            "active_agent_sessions_omitted_count": 0,
            "events": [],
            "recent_events": [],
            "connections": [],
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor BehaviorPersistenceGate {
    private var isOpen = false
    private var operationContinuation: CheckedContinuation<Void, Never>?
    private var blockedContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        let waiters = blockedContinuations
        blockedContinuations.removeAll()
        waiters.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            operationContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard operationContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            blockedContinuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        operationContinuation?.resume()
        operationContinuation = nil
    }
}
