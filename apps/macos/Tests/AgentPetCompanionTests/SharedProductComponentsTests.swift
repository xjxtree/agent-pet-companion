import AppKit
import SwiftUI
import Testing
@testable import AgentPetCompanion
@testable import AgentPetCompanionCore

@Suite("Shared control-center product components")
struct SharedProductComponentsTests {
    @Test
    func statusAppearanceCoversEveryLifecycleAndConnectionState() {
        #expect(
            ProductLifecycleState.allCases.map(ProductStatusAppearance.init(lifecycle:))
                == [
                    .normal,
                    .checking,
                    .checking,
                    .attention,
                    .attention,
                    .normal,
                    .error,
                ]
        )
        #expect(
            AgentConnectionHealthState.allCases.map(
                ProductStatusAppearance.init(connectionHealth:)
            ) == [.checking, .normal, .attention, .error]
        )
        #expect(Set(ProductStatusAppearance.allCases) == [
            .normal,
            .attention,
            .error,
            .checking,
        ])
    }

    @Test
    func actionPresentationKeepsMutationAuthoritySemantic() {
        let sharedDisplayCopy = "Continue"
        let repair = ProductActionPresentation(
            action: AgentConnectionPrimaryAction.repair,
            title: sharedDisplayCopy
        )
        let verify = ProductActionPresentation(
            action: AgentConnectionPrimaryAction.verify,
            title: sharedDisplayCopy
        )

        #expect(repair.title == verify.title)
        #expect(repair.action == .repair)
        #expect(verify.action == .verify)
        #expect(repair != verify)

        let connectionActions: [AgentConnectionPrimaryAction] = [
            .connect,
            .repair,
            .verify,
            .retry,
            .unavailable,
        ]
        let libraryActions: [PetLibraryPrimaryAction] = [
            .usePet,
            .createPet,
            .importPet,
            .unavailable,
        ]
        let makerActions: [PetMakerPrimaryAction] = [
            .createPet,
            .sendReply,
            .cancel,
            .retry,
            .reselectReferences,
            .usePet,
            .continueEditing,
            .unavailable,
        ]
        let diagnosticsActions: [ServiceDiagnosticsPrimaryAction] = [
            .refresh,
            .recover,
            .retry,
            .unavailable,
        ]

        #expect(
            connectionActions.map {
                ProductActionPresentation(action: $0, title: sharedDisplayCopy).action
            } == connectionActions
        )
        #expect(
            libraryActions.map {
                ProductActionPresentation(action: $0, title: sharedDisplayCopy).action
            } == libraryActions
        )
        #expect(
            makerActions.map {
                ProductActionPresentation(action: $0, title: sharedDisplayCopy).action
            } == makerActions
        )
        #expect(
            diagnosticsActions.map {
                ProductActionPresentation(action: $0, title: sharedDisplayCopy).action
            } == diagnosticsActions
        )
    }

    @Test
    func componentAccessibilityIdentifiersAreStableAndUnique() {
        let page = ProductComponentIdentity(scope: "connections")
        let componentIdentifiers = SharedProductComponentKind.allCases.map {
            page.accessibilityIdentifier(for: $0)
        }

        #expect(Set(componentIdentifiers).count == SharedProductComponentKind.allCases.count)
        #expect(
            page.accessibilityIdentifier(for: .pageHeader)
                == "product.connections.page-header"
        )

        let codex = ProductComponentIdentity(scope: "connections", instance: "codex")
        let pi = ProductComponentIdentity(scope: "connections", instance: "pi")
        #expect(
            codex.accessibilityIdentifier(for: .agentHealthRow)
                == "product.connections.codex.agent-health-row"
        )
        #expect(
            codex.accessibilityIdentifier(for: .agentHealthRow)
                != pi.accessibilityIdentifier(for: .agentHealthRow)
        )
        #expect(
            codex.accessibilityIdentifier(
                for: .agentHealthRow,
                suffix: "primary-action"
            ) != codex.accessibilityIdentifier(for: .agentHealthRow)
        )
    }

    @Test
    func attentionPresetOptionsKeepCustomDerivedAndNonSelectableByDefault() {
        let options = AttentionPreset.allCases.map {
            AttentionPresetOption(
                preset: $0,
                title: $0.rawValue,
                detail: "detail"
            )
        }

        #expect(options.map(\.preset) == AttentionPreset.allCases)
        #expect(options.filter(\.isSelectable).map(\.preset) == [
            .onlyWhenNeeded,
            .standard,
            .allActivity,
        ])
        #expect(options.first(where: { $0.preset == .custom })?.isSelectable == false)
    }

    @Test
    func sessionDetailSuppressesOnlyEmptyOrRepeatedCopy() {
        #expect(
            SharedProductComponentText.distinctDetail(
                "Working",
                comparedTo: ["Session", "working"]
            ) == nil
        )
        #expect(
            SharedProductComponentText.distinctDetail(
                "  ",
                comparedTo: ["Session", "Working"]
            ) == nil
        )
        #expect(
            SharedProductComponentText.distinctDetail(
                "Running the test suite",
                comparedTo: ["Session", "Working"]
            ) == "Running the test suite"
        )
    }

    @MainActor
    @Test(arguments: SharedProductCopyFixture.all)
    func completeComponentSetBuildsAtMinimumWidth(
        copy: SharedProductCopyFixture
    ) throws {
        let width = SharedProductComponentLayout.supportedMinimumContentWidth
        let root = SharedProductComponentFixture(copy: copy)
            .frame(width: width)
            .padding(1)
            .environment(\.colorScheme, .light)
        let hostingView = NSHostingView(rootView: root)
        let fittingSize = hostingView.fittingSize

        #expect(fittingSize.width <= width + 2.5)
        #expect(fittingSize.height > 0)
        #expect(fittingSize.height.isFinite)

        hostingView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: width + 2, height: ceil(fittingSize.height))
        )
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try #require(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
        #expect(hasVisibleInk(in: bitmap))
    }

    @MainActor
    @Test(arguments: SharedProductCopyFixture.all)
    func longRequiredActionCopyWrapsInsteadOfUsingSingleLineTruncation(
        copy: SharedProductCopyFixture
    ) {
        let availableWidth: CGFloat = 150
        let shortHeight = fittingHeight(
            of: ProductActionLabel(title: "Retry", systemImage: "arrow.clockwise"),
            width: availableWidth
        )
        let longHeight = fittingHeight(
            of: ProductActionLabel(
                title: copy.primaryAction,
                systemImage: "arrow.clockwise"
            ),
            width: availableWidth
        )

        #expect(longHeight > shortHeight)
    }

    @MainActor
    private func fittingHeight<Content: View>(
        of view: Content,
        width: CGFloat
    ) -> CGFloat {
        NSHostingView(rootView: view.frame(width: width)).fittingSize.height
    }

    private func hasVisibleInk(in bitmap: NSBitmapImageRep) -> Bool {
        let stride = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 40)
        for x in Swift.stride(from: 0, to: bitmap.pixelsWide, by: stride) {
            for y in Swift.stride(from: 0, to: bitmap.pixelsHigh, by: stride) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent > 0.05 { return true }
            }
        }
        return false
    }
}

struct SharedProductCopyFixture: CustomTestStringConvertible, Sendable {
    let language: String
    let pageTitle: String
    let summary: String
    let status: String
    let detail: String
    let primaryAction: String
    let advancedTitle: String
    let presets: [AttentionPresetOption]

    var testDescription: String { language }

    static let all = [english, simplifiedChinese]

    static let english = SharedProductCopyFixture(
        language: "English",
        pageTitle: "Agent Connections",
        summary: "Connect or repair an Agent integration with one clear action and quiet technical details.",
        status: "Needs Repair",
        detail: "Event delivery needs attention before the desktop pet can notify you.",
        primaryAction: "Reconnect this coding Agent and verify event delivery",
        advancedTitle: "Technical Details and Managed Integration Information",
        presets: [
            AttentionPresetOption(
                preset: .onlyWhenNeeded,
                title: "Only When I Am Needed",
                detail: "Show waiting, review, and failed messages."
            ),
            AttentionPresetOption(
                preset: .standard,
                title: "Standard",
                detail: "Show important progress and attention messages."
            ),
            AttentionPresetOption(
                preset: .allActivity,
                title: "All Activity",
                detail: "Show all six persisted event types."
            ),
            AttentionPresetOption(
                preset: .custom,
                title: "Custom",
                detail: "Your advanced event choices are active."
            ),
        ]
    )

    static let simplifiedChinese = SharedProductCopyFixture(
        language: "简体中文",
        pageTitle: "Agent 连接",
        summary: "通过一个清晰操作连接或修复 Agent 集成，并按需展开技术详情。",
        status: "需要修复",
        detail: "桌宠向你发送通知之前，需要先恢复 Agent 的消息事件传递。",
        primaryAction: "重新连接这个编码 Agent 并验证消息事件是否能够正常送达",
        advancedTitle: "技术详情与受管理的 Agent 集成信息",
        presets: [
            AttentionPresetOption(
                preset: .onlyWhenNeeded,
                title: "只在需要我时",
                detail: "显示等待处理、可以查看和遇到问题的消息。"
            ),
            AttentionPresetOption(
                preset: .standard,
                title: "标准",
                detail: "显示重要进展和需要注意的消息。"
            ),
            AttentionPresetOption(
                preset: .allActivity,
                title: "全部活动",
                detail: "显示全部六种持久化消息事件。"
            ),
            AttentionPresetOption(
                preset: .custom,
                title: "自定义",
                detail: "当前正在使用你在高级设置中的事件选择。"
            ),
        ]
    )
}

private struct SharedProductComponentFixture: View {
    let copy: SharedProductCopyFixture

    var body: some View {
        VStack(alignment: .leading, spacing: SharedProductComponentLayout.pageSpacing) {
            ProductPageHeader(
                identity: ProductComponentIdentity(scope: "fixture"),
                title: copy.pageTitle,
                summary: copy.summary
            )

            PrimaryExperienceCard(
                identity: ProductComponentIdentity(scope: "fixture"),
                title: copy.pageTitle,
                summary: copy.summary,
                status: ProductStatusPresentation(
                    appearance: .attention,
                    title: copy.status,
                    detail: copy.detail
                ),
                primaryAction: ProductActionPresentation(
                    action: AgentConnectionPrimaryAction.repair,
                    title: copy.primaryAction,
                    systemImage: "wrench.and.screwdriver"
                ),
                onPrimaryAction: { _ in }
            ) {
                Text(copy.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PetPreviewStage(
                identity: ProductComponentIdentity(scope: "fixture"),
                accessibilityLabel: copy.pageTitle
            ) {
                Image(systemName: "pawprint.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .foregroundStyle(.secondary)
            }

            ForEach(
                Array(AgentConnectionHealthState.allCases.enumerated()),
                id: \.offset
            ) { index, health in
                AgentHealthRow(
                    identity: ProductComponentIdentity(
                        scope: "fixture",
                        instance: "agent-\(index)"
                    ),
                    agentTitle: "Codex",
                    agentSummary: copy.detail,
                    health: health,
                    healthTitle: copy.status,
                    primaryAction: ProductActionPresentation(
                        action: AgentConnectionPrimaryAction.repair,
                        title: copy.primaryAction,
                        systemImage: "wrench.and.screwdriver"
                    ),
                    onPrimaryAction: { _ in }
                )
            }

            SharedProductComponents.SessionBubbleRow(
                identity: ProductComponentIdentity(
                    scope: "fixture",
                    instance: "session-alpha"
                ),
                agentTitle: "Codex",
                sessionTitle: copy.pageTitle,
                lifecycle: .tool,
                statusTitle: copy.status,
                message: copy.detail,
                navigationAction: ProductActionPresentation(
                    action: NavigationCapability.agentHost,
                    title: copy.primaryAction,
                    systemImage: "arrow.up.forward.app"
                ),
                onNavigationAction: { _ in }
            )

            AttentionPresetPicker(
                identity: ProductComponentIdentity(scope: "fixture"),
                title: copy.pageTitle,
                selection: .onlyWhenNeeded,
                options: copy.presets,
                onSelection: { _ in }
            )

            AdvancedDetailsDisclosure(
                identity: ProductComponentIdentity(scope: "fixture"),
                title: copy.advancedTitle,
                summary: copy.summary,
                isExpanded: .constant(true)
            ) {
                Text(copy.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }

            EmptyStateAction(
                identity: ProductComponentIdentity(scope: "fixture"),
                status: ProductStatusPresentation(
                    appearance: .normal,
                    title: copy.status
                ),
                message: copy.summary,
                primaryAction: ProductActionPresentation(
                    action: PetLibraryPrimaryAction.createPet,
                    title: copy.primaryAction,
                    systemImage: "sparkles"
                ),
                onPrimaryAction: { _ in }
            )

            ForEach(
                Array(ProductStatusAppearance.allCases.enumerated()),
                id: \.offset
            ) { index, appearance in
                InlineRecoveryBanner(
                    identity: ProductComponentIdentity(
                        scope: "fixture",
                        instance: "banner-\(index)"
                    ),
                    status: ProductStatusPresentation(
                        appearance: appearance,
                        title: copy.status,
                        detail: copy.detail
                    ),
                    primaryAction: ProductActionPresentation(
                        action: ServiceDiagnosticsPrimaryAction.retry,
                        title: copy.primaryAction,
                        systemImage: "arrow.clockwise"
                    ),
                    onPrimaryAction: { _ in }
                )
            }
        }
    }
}
