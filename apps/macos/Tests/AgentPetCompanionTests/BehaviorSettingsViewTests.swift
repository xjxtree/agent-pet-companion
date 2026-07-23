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
                == [.start, .tool, .waiting, .review, .done, .failed]
        )
    }

    @Test
    func appearanceCatalogKeepsTheClosedThemeAndFpsProfiles() {
        #expect(BehaviorSettingsCatalog.appearanceThemes == [.system, .light, .dark])
        #expect(BehaviorSettingsCatalog.fpsProfiles == [.standard, .smooth])
        #expect(BehaviorSettingsCatalog.fpsProfiles.map(\.fps) == [10, 20])
        #expect(BehaviorSettingsCatalog.groupDisplays == [.stacked, .expanded])
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
        #expect(standard[0].detail.contains("Needs confirmation"))
        #expect(standard[0].detail.contains("Failed"))
        #expect(!standard[0].detail.contains("Starting"))
        #expect(standard[1].detail.contains("Starting"))
        #expect(!standard[1].detail.contains("Using a tool"))
        #expect(standard[2].detail.contains("Using a tool"))

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
    func nativeFrameRateLimitsTheAvailablePlaybackProfiles() {
        let standardPet = PetSummary(
            id: "pet_standard",
            name: "Standard",
            style: "pixel",
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: "/standard.petpack",
            coverPath: "",
            nativeFPS: 10,
            active: true,
            createdAt: "2026-07-22T00:00:00Z"
        )
        var smoothPet = standardPet
        smoothPet.nativeFPS = 20

        #expect(BehaviorSettingsCatalog.supportedFPSProfiles(for: standardPet) == [.standard])
        #expect(BehaviorSettingsCatalog.supportedFPSProfiles(for: smoothPet) == [.standard, .smooth])
        #expect(BehaviorSettingsCatalog.supportedFPSProfiles(for: nil) == [.standard])
        #expect(standardPet.effectiveFPSProfile(.smooth) == .standard)
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

        #expect(connection.health == .needsRepair)
        #expect(
            ConfigurationSourcePresentation.detail(
                source: .codex,
                status: status,
                operationState: .idle,
                localeIdentifier: "en"
            ) == "Needs Repair"
        )
    }

    @MainActor
    @Test
    func appStoreDefensivelyDowngradesUnsupportedSmoothSelection() {
        let store = AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            )
        )
        store.pets = [PetSummary(
            id: "pet_standard",
            name: "Standard",
            style: "pixel",
            quality: .high,
            renderSize: QualityLevel.high.renderSize,
            petpackPath: "/standard.petpack",
            coverPath: "",
            nativeFPS: 10,
            active: true,
            createdAt: "2026-07-22T00:00:00Z"
        )]
        var next = store.behavior
        next.fpsProfile = .smooth

        store.updateBehavior(next)

        #expect(store.behavior.fpsProfile == .standard)
        #expect(store.effectiveFPSProfile == .standard)
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
        #expect(source.contains("settingsColumn(showsInlinePreview: false)"))
        #expect(!source.contains("BehaviorSettingsSubnavigation"))
        #expect(!source.contains("configuration.subnavigation"))
        #expect(!source.contains("navigationWidth"))
        #expect(!source.contains("configuration.preview.resize-handle"))
        #expect(source.contains("Text(APCLocalization.text(.configSizeFooter))"))
    }

    @MainActor
    @Test
    func transparencyDragPreviewsLocallyAndCommitsExactlyOneRPC() async throws {
        let probe = BehaviorRequestProbe()
        let persisted = BehaviorSettings(bubbleTransparency: 0.8)
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
            petCoreRequestOverride: { method, params, _ in
                probe.requests.append((method, params))
                return [
                    "behavior": persistedObject,
                    "revision": "1",
                ]
            }
        )
        let original = store.behavior.bubbleTransparency

        store.previewBubbleTransparency(0.6)
        store.previewBubbleTransparency(0.7)
        store.previewBubbleTransparency(0.8)

        #expect(probe.requests.isEmpty)
        #expect(store.behavior.bubbleTransparency == 0.8)

        store.commitBubbleTransparency(from: original)
        await store.waitForBehaviorPersistence()

        #expect(probe.requests.count == 1)
        #expect(probe.requests.first?.method == "behavior.patch")
        let parameters = probe.requests.first?.params as? [String: Any]
        let changes = parameters?["changes"] as? [String: Any]
        #expect(changes?["bubble_transparency"] as? Double == 0.8)
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
    private func makeStore(probe: BehaviorPersistenceProbe) -> AppStore {
        AppStore(
            bootstrapHooks: AppStoreBootstrapHooks(
                ensureRunning: { .alreadyHealthy },
                recover: { .alreadyHealthy },
                refreshSnapshot: { _ in },
                onReady: { _ in }
            ),
            applicationAppearanceApplier: { _ in },
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
private final class BehaviorRequestProbe {
    var requests: [(method: String, params: Any)] = []
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
            return [:]
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
