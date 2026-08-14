import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Control Center shell")
struct ControlCenterShellTests {
    @Test @MainActor
    func controlCenterWindowHidesOnlyTheTitlebarSeparator() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.titlebarSeparatorStyle = .line

        ControlCenterWindowChrome.hideTitlebarSeparator(in: window)

        #expect(window.titlebarSeparatorStyle == .none)
    }

    @Test
    func navigationUsesTheFixedProductOrderAndTypedSelection() {
        let items = ControlCenterNavigationPresentation.items(
            selection: .configuration,
            localeIdentifier: "en"
        )

        #expect(ControlCenterNavigationPresentation.orderedSections == [
            .library,
            .maker,
            .configuration,
            .connections,
            .diagnostics,
        ])
        #expect(ControlCenterNavigationPresentation.orderedSections == NavigationSection.allCases)
        #expect(items.map(\.section) == ControlCenterNavigationPresentation.orderedSections)
        #expect(items.filter(\.isSelected).map(\.section) == [.configuration])
        #expect(items.map(\.title) == [
            "Pet Library",
            "AI Pet Maker",
            "Pet Configuration",
            "Agent Connections",
            "Service & Diagnostics",
        ])
    }

    @Test
    func navigationCopyFitsTheSidebarInEnglishAndChinese() {
        let availableTitleWidth =
            ControlCenterShellPolicy.primarySidebarMinimumWidth - 72
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        for locale in ["en", "zh-Hans"] {
            let items = ControlCenterNavigationPresentation.items(
                selection: .library,
                localeIdentifier: locale
            )
            #expect(items.count == 5)
            for item in items {
                let titleWidth = (item.title as NSString).size(
                    withAttributes: [.font: font]
                ).width
                #expect(titleWidth <= availableTitleWidth)
            }
        }
    }

    @Test
    func responsivePolicyPreservesTheSupportedMinimumWindow() {
        #expect(ControlCenterShellPolicy.supportedMinimumWindowWidth == 760)
        #expect(ControlCenterShellPolicy.supportedMinimumWindowHeight == 520)
        #expect(
            ControlCenterShellPolicy(
                windowWidth: ControlCenterShellPolicy.supportedMinimumWindowWidth
            ).mode == .singleContent
        )
        #expect(
            ControlCenterShellPolicy(windowWidth: 879).preferredColumnVisibility
                == .detailOnly
        )
        #expect(
            ControlCenterShellPolicy(windowWidth: 880).mode
                == .sidebarAndContent
        )
        #expect(
            ControlCenterShellPolicy(windowWidth: 1_120).mode
                == .allColumns
        )
        #expect(
            ControlCenterShellPolicy.supportedMinimumWindowWidth
                >= SharedProductComponentLayout.supportedMinimumContentWidth
        )
    }

    @Test
    func healthyAndCheckingServicesDoNotOccupyTheToolbar() {
        #expect(ControlCenterServiceAttentionPresentation.resolve(
            for: .online,
            localeIdentifier: "en"
        ) == nil)
        #expect(ControlCenterServiceAttentionPresentation.resolve(
            for: .checking,
            localeIdentifier: "zh-Hans"
        ) == nil)
    }

    @Test
    func recoveryAndEveryFailureClassExposeOneLocalizedAttentionEntry() throws {
        let recovering = try #require(ControlCenterServiceAttentionPresentation.resolve(
            for: .recovering,
            localeIdentifier: "en"
        ))
        let offline = try #require(ControlCenterServiceAttentionPresentation.resolve(
            for: .offline,
            localeIdentifier: "zh-Hans"
        ))
        let mismatch = try #require(ControlCenterServiceAttentionPresentation.resolve(
            for: .runtimeMismatch,
            localeIdentifier: "en"
        ))
        let error = try #require(ControlCenterServiceAttentionPresentation.resolve(
            for: .error,
            localeIdentifier: "zh-Hans"
        ))

        #expect(recovering.title == "Recovering service")
        #expect(recovering.appearance == .checking)
        #expect(offline.title == "服务离线")
        #expect(offline.appearance == .error)
        #expect(mismatch.title == "Compatibility issue")
        #expect(mismatch.appearance == .attention)
        #expect(error.title == "服务异常")
        #expect(error.appearance == .error)
    }

    @Test
    func globalFailureBannerRoutesToDiagnosticsWithoutDuplicatingRecovery() throws {
        #expect(ControlCenterRecoveryBannerPresentation.resolve(
            for: .online,
            localeIdentifier: "en"
        ) == nil)
        #expect(ControlCenterRecoveryBannerPresentation.resolve(
            for: .checking,
            localeIdentifier: "en"
        ) == nil)
        #expect(ControlCenterRecoveryBannerPresentation.resolve(
            for: .recovering,
            localeIdentifier: "en"
        ) == nil)

        let offline = try #require(ControlCenterRecoveryBannerPresentation.resolve(
            for: .offline,
            localeIdentifier: "en"
        ))
        #expect(offline.status.title == "Service offline")
        #expect(
            offline.status.detail
                == "PetCore cannot currently be reached on the local transport."
        )
        #expect(offline.primaryAction.action == .openDiagnostics)
        #expect(offline.primaryAction.title == "Service & Diagnostics")

        let mismatch = try #require(ControlCenterRecoveryBannerPresentation.resolve(
            for: .runtimeMismatch,
            localeIdentifier: "zh-Hans"
        ))
        #expect(mismatch.status.title == "兼容性不匹配")
        #expect(mismatch.primaryAction.title == "服务与诊断")
    }

    @Test
    func startupConnectionCheckAndConcreteIssuesUseOneGlobalRoute() throws {
        let checking = try #require(
            ControlCenterAgentConnectionBannerPresentation.resolve(
                startupState: .checking,
                connections: [],
                operationState: .idle,
                serviceState: .online,
                convergenceState: .idle,
                localeIdentifier: "zh-Hans"
            )
        )
        #expect(checking.status.appearance == .checking)
        #expect(checking.status.title == "正在检查 Agent 连接")
        #expect(checking.primaryAction.action == .openConnections)

        let pluginUpdate = connectionStatus(
            source: .codex,
            checkStatus: .needsFix,
            managedComponentStatus: .needsFix
        )
        let healthy = AgentSource.allCases.dropFirst().map {
            connectionStatus(source: $0)
        }
        let attention = try #require(
            ControlCenterAgentConnectionBannerPresentation.resolve(
                startupState: .completed,
                connections: [pluginUpdate] + healthy,
                operationState: .succeeded(.init(
                    kind: .check,
                    sources: AgentSource.allCases
                )),
                serviceState: .online,
                convergenceState: .idle,
                localeIdentifier: "zh-Hans"
            )
        )

        #expect(attention.status.appearance == .attention)
        #expect(attention.affectedSources == [.codex])
        #expect(attention.status.detail?.contains("Codex") == true)
        #expect(attention.status.detail?.contains("插件或连接器需要设置或更新") == true)
        #expect(attention.primaryAction.title == "Agent 连接")
    }

    @Test
    func awaitingRealTaskVerificationIsNotReportedAsAConnectionFailure() {
        let statuses = AgentSource.allCases.map {
            connectionStatus(source: $0, verification: .unverified)
        }

        #expect(ControlCenterAgentConnectionBannerPresentation.resolve(
            startupState: .completed,
            connections: statuses,
            operationState: .succeeded(.init(
                kind: .check,
                sources: AgentSource.allCases
            )),
            serviceState: .online,
            convergenceState: .idle,
            localeIdentifier: "en"
        ) == nil)
    }

    @Test
    func healthyLightSnapshotsAfterRuntimeCacheExpiryDoNotCreateFalseAttention() {
        let statuses = AgentSource.allCases.map {
            connectionStatus(source: $0, checkMode: .light)
        }

        #expect(ControlCenterAgentConnectionBannerPresentation.resolve(
            startupState: .completed,
            connections: statuses,
            operationState: .succeeded(.init(
                kind: .check,
                sources: AgentSource.allCases
            )),
            serviceState: .online,
            convergenceState: .idle,
            localeIdentifier: "zh-Hans"
        ) == nil)
    }

    @Test
    func lightSnapshotsStillReportConcreteConnectionIssues() throws {
        let needsRepair = connectionStatus(
            source: .codex,
            checkStatus: .needsFix,
            managedComponentStatus: .needsFix,
            checkMode: .light
        )
        let healthy = AgentSource.allCases.dropFirst().map {
            connectionStatus(source: $0, checkMode: .light)
        }

        let attention = try #require(
            ControlCenterAgentConnectionBannerPresentation.resolve(
                startupState: .completed,
                connections: [needsRepair] + healthy,
                operationState: .succeeded(.init(
                    kind: .check,
                    sources: AgentSource.allCases
                )),
                serviceState: .online,
                convergenceState: .idle,
                localeIdentifier: "zh-Hans"
            )
        )

        #expect(attention.affectedSources == [.codex])
        #expect(attention.status.detail?.contains("Codex") == true)
        #expect(attention.status.detail?.contains("插件或连接器需要设置或更新") == true)
    }

    @Test
    func connectionCheckFailureAndUpdateAttentionDoNotDuplicateBanners() throws {
        let failedOperation = AgentConnectionOperation(
            kind: .check,
            sources: AgentSource.allCases
        )
        let failure = try #require(
            ControlCenterAgentConnectionBannerPresentation.resolve(
                startupState: .failed(.transportUnavailable),
                connections: [],
                operationState: .failed(.init(
                    operation: failedOperation,
                    reason: .transportUnavailable
                )),
                serviceState: .online,
                convergenceState: .idle,
                localeIdentifier: "en"
            )
        )
        #expect(failure.status.appearance == .error)
        #expect(failure.status.title == "Agent connection operation did not finish")
        #expect(failure.primaryAction.action == .openConnections)

        let updateIssue = ProductConnectorConvergenceIssue(
            source: .codex,
            reason: .verificationIncomplete
        )
        #expect(ControlCenterAgentConnectionBannerPresentation.resolve(
            startupState: .failed(.transportUnavailable),
            connections: [],
            operationState: .failed(.init(
                operation: failedOperation,
                reason: .transportUnavailable
            )),
            serviceState: .online,
            convergenceState: .needsAttention(.connectors([updateIssue])),
            localeIdentifier: "en"
        ) == nil)
    }

    @Test
    func toolbarContainsNoOverflowNavigationDuplicate() throws {
        let contentSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "Views/ContentView.swift"
            ),
            encoding: .utf8
        )

        #expect(contentSource.contains("InlineRecoveryBanner("))
        #expect(contentSource.contains("ControlCenterWindowChromeBridge()"))
        #expect(contentSource.contains("titlebarSeparatorStyle = .none"))
        #expect(contentSource.contains("store.selection = .diagnostics"))
        #expect(contentSource.contains("if let serviceAttention"))
        #expect(!contentSource.contains("toolbar.service-status"))
        #expect(!contentSource.contains("toolbar.more"))
        #expect(!contentSource.contains("Button(APCLocalization.text(.navigationConnections))"))
        #expect(!contentSource.contains("Menu {"))
    }

    @Test
    func detailPagesReceiveAFiniteViewportInsteadOfTheirIdealContentHeight() throws {
        let contentSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "Views/ContentView.swift"
            ),
            encoding: .utf8
        )

        #expect(contentSource.contains("ControlCenterDetailViewport {"))
        #expect(contentSource.contains("width: geometry.size.width"))
        #expect(contentSource.contains("height: geometry.size.height"))
        #expect(contentSource.contains("ControlCenterDetailViewport {\n                        VStack(spacing: 0)"))
        #expect(contentSource.contains("mainContent\n                                .frame("))
        #expect(contentSource.contains(".layoutPriority(1)"))
    }

    @Test
    func petPreviewIsGlobalAndAboveTheSidebarIdentityRow() throws {
        let sidebarSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "Views/SidebarView.swift"
            ),
            encoding: .utf8
        )
        let preview = try #require(
            sidebarSource.range(of: "SidebarConfigurationLivePreview(")
        )
        let identity = try #require(sidebarSource.range(of: "APCBrandMark(size: 18)"))

        #expect(preview.lowerBound < identity.lowerBound)
        #expect(!sidebarSource.contains("store.selection == .configuration"))
        #expect(!sidebarSource.contains("PetCoverImage("))
        #expect(sidebarSource.contains("displayWidthPt: store.overlayDisplayWidthPt"))
        #expect(sidebarSource.contains("assetWarning: activePetAssetWarning"))
        #expect(!sidebarSource.contains(".safeAreaInset(edge: .bottom"))
        #expect(sidebarSource.contains(".scrollContentBackground(.hidden)"))
        #expect(sidebarSource.contains(".background(.bar, ignoresSafeAreaEdges: .all)"))
        #expect(sidebarSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(sidebarSource.contains(".layoutPriority(1)"))
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion", isDirectory: true)
    }

    private func connectionStatus(
        source: AgentSource,
        checkStatus: CheckStatus = .ok,
        managedComponentStatus: CheckStatus = .ok,
        checkMode: ConnectionCheckMode = .runtime,
        verification: AgentVerificationStatus = .verified
    ) -> AgentConnectionStatus {
        AgentConnectionStatus(
            source: source,
            items: [
                ConnectionCheckItem(
                    code: .managedConnector,
                    name: "managed connector",
                    status: checkStatus,
                    detail: "bounded test detail",
                    recoveryAction: checkStatus.isBlocking
                        ? .confirmManagedRepair
                        : nil
                )
            ],
            installPaths: [],
            connectorInstalled: checkStatus == .ok,
            checkMode: checkMode,
            verification: AgentVerification(
                status: verification,
                title: "verification",
                detail: "verification detail"
            ),
            capabilities: AgentConnectorCapabilities(
                contractVersion: "typed-test-v1",
                subscribedEvents: [],
                mappedInformation: [],
                privacyExclusions: [],
                repairableConnectorIssue: checkStatus.isBlocking,
                canRepairManagedConnector: true,
                managedPathConflict: false,
                canUninstallManagedConnector: true,
                managedComponents: [
                    AgentManagedComponent(
                        kind: .plugin,
                        name: "agent-pet-companion",
                        ownership: .appManaged,
                        status: managedComponentStatus,
                        expectedVersion: "1.1.0",
                        activeVersion: managedComponentStatus == .ok
                            ? "1.1.0"
                            : "1.0.0",
                        contentMatches: managedComponentStatus == .ok
                    )
                ]
            )
        )
    }
}
