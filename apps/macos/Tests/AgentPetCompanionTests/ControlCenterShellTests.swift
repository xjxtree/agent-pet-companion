import AppKit
import Foundation
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Control Center shell")
struct ControlCenterShellTests {
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
    func toolbarContainsNoOverflowNavigationDuplicate() throws {
        let contentSource = try String(
            contentsOf: sourceDirectory.appendingPathComponent(
                "Views/ContentView.swift"
            ),
            encoding: .utf8
        )

        #expect(contentSource.contains("InlineRecoveryBanner("))
        #expect(contentSource.contains("store.selection = .diagnostics"))
        #expect(contentSource.contains("if let serviceAttention"))
        #expect(!contentSource.contains("toolbar.service-status"))
        #expect(!contentSource.contains("toolbar.more"))
        #expect(!contentSource.contains("Button(APCLocalization.text(.navigationConnections))"))
        #expect(!contentSource.contains("Menu {"))
    }

    private var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentPetCompanion", isDirectory: true)
    }
}
